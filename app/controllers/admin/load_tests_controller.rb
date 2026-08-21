# -*- encoding : utf-8 -*-
#
# The console front door onto LoadTest::Seeder. It does not reimplement any of
# it: a screen holding its own copy of the seeding logic would drift from the
# rake task, and the two are used on the same night by the same person.
#
# Seeding itself runs off the request thread. #seed! took ten minutes for a
# 120-team cohort before 2026-08-21's speed fix, and ten minutes in a Puma
# thread is wrong regardless of how fast that fix makes it -- see
# docs/superpowers/specs/2026-08-21-load-testing-design.md and
# TranslationRunsController's identical Thread pattern, which this mirrors.
class Admin::LoadTestsController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!

  def show
    @status = LoadTest::Seeder.status
    @games  = Game.order(:name)
    # Written by the background thread below when it fails; read once and
    # cleared so the console does not keep repeating a resolved failure on
    # every later visit. Process-local (Rails.cache) and does not survive a
    # restart -- acceptable, because the durable signal that something went
    # wrong is that no cohort appears, not this message.
    @seed_error = Rails.cache.read(LoadTest::Seeder::ERROR_CACHE_KEY)
    Rails.cache.delete(LoadTest::Seeder::ERROR_CACHE_KEY) if @seed_error
  end

  def seed
    cohort_id = params[:cohort_id].to_s
    return refuse unless confirmed?(cohort_id)
    return refuse_invalid unless valid_cohort_id?(cohort_id)

    # The typed confirmation IS the console's per-operation confirmation --
    # `confirmed?` above already enforced it. Passing it through here too
    # makes the guard defence in depth: it still refuses in production even
    # if `confirmed?` were ever removed or bypassed, rather than silently
    # trusting the caller the way `LoadTest.guard!(cohort_id)` alone would
    # (its default reads LOAD_TEST_CONFIRM, which is never set in this
    # process -- see the Puma/rake split in lib/load_test.rb). Kept
    # synchronous: it is fast (no database write at all), unlike the seed
    # itself below.
    LoadTest.guard!(cohort_id, :confirmation => params[:confirm_cohort_id])

    # Captured as plain values, not read inside the thread below: current_user
    # is request state (session/warden), and the thread outlives this request
    # -- see AdminAudit's comment on why record_admin_action itself cannot be
    # reused there. I18n.locale is thread-local, too -- a new Thread starts at
    # I18n.default_locale regardless of what this request negotiated, so a
    # non-default-locale operator's eventual failure message (perform_seed's
    # t() calls) would silently come back in the wrong language without this.
    source_game_id = params[:source_game_id]
    teams           = params[:teams]
    base_url        = request.base_url
    actor_id        = current_user&.id
    actor_label     = current_user&.nickname
    locale          = I18n.locale

    run_in_background do
      I18n.with_locale(locale) do
        perform_seed(source_game_id, teams, cohort_id, base_url, actor_id, actor_label)
      end
    end

    redirect_to admin_load_test_path, :notice => t("admin.load_test.seed_started")
  # LoadTest::Seeder::CohortPresent, LoadTest::Seeder::AlreadySeeding and
  # ActiveRecord::RecordInvalid used to be rescued here too, back when #seed!
  # ran synchronously in this action. Now it runs in the thread spawned
  # above, so those three surface through perform_seed's own rescue and
  # Rails.cache instead -- see that method. Only LoadTest::Refused is still
  # raised synchronously (by the guard! call above, before any thread
  # exists), so it is the only one still rescued here.
  rescue LoadTest::Refused
    redirect_to admin_load_test_path, :alert => t("admin.load_test.refused")
  end

  def teardown
    cohort_id = params[:cohort_id].to_s
    return refuse unless confirmed?(cohort_id)
    return refuse_invalid unless valid_cohort_id?(cohort_id)

    # See the matching comment in #seed. Teardown stays synchronous
    # throughout -- it is fast, and the operator should see it finish.
    LoadTest.guard!(cohort_id, :confirmation => params[:confirm_cohort_id])
    removed = LoadTest::Seeder.teardown!(cohort_id)

    # Audited immediately, before the manifest cleanup below. The change that
    # touched the database is the teardown; File.unlink below can raise (the
    # exist?/unlink pair is a TOCTOU race, and /tmp is where a cleaner
    # intervenes), and a raise there must not be able to erase the record of
    # who deleted a live cohort. Mirrors the identical fix in #seed.
    record_admin_action("load_test_teardown", nil,
                        "cohort=#{cohort_id}, rows=#{removed}")

    # The credentials outlive the accounts otherwise. Best-effort: a manifest
    # we cannot remove is worth a warning, not a 500 on a teardown that
    # already succeeded. The path is DERIVED from the cohort id (see
    # #manifest_path), not read back from anywhere -- there is nothing to
    # read it back from now that seeding no longer stashes it in the session.
    begin
      File.unlink(manifest_path(cohort_id))
    rescue Errno::ENOENT
      # Already gone -- nothing to do.
    rescue SystemCallError => e
      Rails.logger.warn("[load_test] could not remove manifest #{manifest_path(cohort_id)}: #{e.class}")
    end

    redirect_to admin_load_test_path, :notice => t("admin.load_test.torn_down")
  rescue LoadTest::Refused
    redirect_to admin_load_test_path, :alert => t("admin.load_test.refused")
  end

  # The path is derived from the cohort id currently present, never stored in
  # the session: the background thread #seed spawns has no session to write
  # to (it outlives the request), so deriving the path here is what makes
  # this action work at all once seeding is off the request thread, and it
  # removes the session dependency entirely rather than replacing it with
  # another one.
  def manifest
    cohort_id = LoadTest::Seeder.status[:cohort_id]
    path      = cohort_id.present? ? manifest_path(cohort_id) : nil

    if path.blank? || !File.exist?(path)
      return redirect_to(admin_load_test_path, :alert => t("admin.load_test.no_manifest"))
    end

    send_data File.read(path), :filename => "load-test-manifest.json",
                               :type => "application/json", :disposition => "attachment"
  end

  private

  # A slug, not free text. cohort_id is written verbatim into a filesystem
  # path (Dir.tmpdir/#{cohort_id}.json -- see manifest_path) and, inside the
  # seeder, into nicknames and e-mail local parts. ManifestFile.write! only
  # refuses paths under Rails.root, so a "../" segment elsewhere on disk is
  # not caught there. This is not remotely exploitable on its own -- only a
  # superadmin reaches this action, and a superadmin can already delete
  # production data outright -- but an id shaped like a path or containing
  # characters e-mail validation rejects would otherwise fail confusingly
  # deep inside the seeder instead of here, at the door.
  COHORT_ID = /\A[a-z0-9][a-z0-9-]{2,63}\z/

  def valid_cohort_id?(cohort_id)
    COHORT_ID.match?(cohort_id)
  end

  def confirmed?(cohort_id)
    cohort_id.present? && params[:confirm_cohort_id].to_s == cohort_id
  end

  def refuse
    redirect_to admin_load_test_path, :alert => t("admin.load_test.not_confirmed")
  end

  def refuse_invalid
    redirect_to admin_load_test_path, :alert => t("admin.load_test.invalid_cohort_id")
  end

  # Cohort id -> filename, fixed and predictable, by design: real usage never
  # has two cohorts at once, so there is nothing to disambiguate. Shared by
  # #manifest (reads it back), #teardown (removes it) and perform_seed
  # (writes it), so the three cannot drift into different naming schemes.
  def manifest_path(cohort_id)
    File.join(Dir.tmpdir, "#{cohort_id}.json")
  end

  # Rails.application.executor.wrap is load-bearing, not ceremony: a bare
  # Thread leaks a connection from the pool and does not participate in code
  # reloading -- see the identical comment on TranslationRunsController#start,
  # which this mirrors. Split into its own method (rather than calling
  # Thread.new directly from #seed) so specs can run the block inline instead
  # of racing a real background thread -- see
  # spec/requests/admin/load_tests_spec.rb.
  def run_in_background
    Thread.new { Rails.application.executor.wrap { yield } }
  end

  # Everything #seed used to do synchronously between calling seed! and
  # rendering a response, now run off the request thread. Ordering mirrors
  # what #seed did before this fix: seed! first (it is what touches the
  # database), the audit row immediately after (a manifest-write failure must
  # not be able to leave a committed cohort with no record of who created
  # it), the manifest write last.
  #
  # current_user is not available here -- there is no request by the time
  # this runs -- so actor_id/actor_label arrive as plain values captured by
  # #seed before the thread was spawned, and the AdminAction row is built
  # directly rather than through record_admin_action (which reads
  # current_user itself).
  def perform_seed(source_game_id, teams, cohort_id, base_url, actor_id, actor_label)
    manifest = LoadTest::Seeder.new(
      :source_game => Game.find(source_game_id),
      :teams       => teams,
      :cohort_id   => cohort_id,
      :base_url    => base_url
    ).seed!

    game = Game.find(manifest[:game_id])
    write_admin_action("load_test_seed", :actor_id => actor_id, :actor_label => actor_label,
                       :target => game,
                       :details => "cohort=#{cohort_id}, source=#{source_game_id}, " \
                                   "teams=#{manifest[:teams].size}")

    LoadTest::ManifestFile.write!(manifest, :path => manifest_path(manifest[:cohort_id]))
  rescue Errno::EEXIST
    # The cohort is live AND recorded above -- only the credentials file is
    # missing. Name the cohort so the operator can still find and tear down
    # what was just created, rather than leaving them with nothing to go on.
    Rails.logger.warn("[load_test] manifest for cohort #{cohort_id} already exists, not overwritten")
    Rails.cache.write(LoadTest::Seeder::ERROR_CACHE_KEY,
                      t("admin.load_test.manifest_exists", :cohort => cohort_id))
  # Errors are surfaced, not swallowed: logged in full here (this is the only
  # place any trace of them survives, since nothing is watching this thread),
  # and reduced to a short operator-facing message the console shows once.
  # LoadTest::Seeder::CohortPresent, LoadTest::Seeder::AlreadySeeding and
  # ActiveRecord::RecordInvalid get their own translated message, matching
  # what #seed used to rescue synchronously before this fix moved seed! off
  # the request thread; anything else gets a generic one.
  rescue StandardError => e
    Rails.logger.error("[load_test] seed failed for cohort #{cohort_id}: " \
                       "#{e.class}: #{e.message}\n#{Array(e.backtrace).join("\n")}")
    Rails.cache.write(LoadTest::Seeder::ERROR_CACHE_KEY, seed_error_message(e, cohort_id))
  end

  def seed_error_message(error, cohort_id)
    case error
    when LoadTest::Seeder::CohortPresent
      t("admin.load_test.cohort_present", :cohort => LoadTest::Seeder.status[:cohort_id] || cohort_id)
    when LoadTest::Seeder::AlreadySeeding
      t("admin.load_test.already_seeding")
    when ActiveRecord::RecordInvalid
      t("admin.load_test.invalid_clone", :errors => error.record.errors.full_messages.join("; "))
    else
      t("admin.load_test.seed_failed")
    end
  end

  # Same fields as AdminAudit#record_admin_action, but taking the actor
  # explicitly instead of reading current_user -- the background thread this
  # runs in has no request to read it from. Named differently (not
  # record_admin_action) on purpose, so it cannot accidentally be called from
  # request context expecting current_user to be consulted; matched by
  # spec/i18n_audit_actions_spec.rb's CALL regex alongside record_admin_action
  # itself, so a new action name written through this method is still found
  # mechanically rather than needing a second, hand-kept list.
  def write_admin_action(action, actor_id:, actor_label:, target: nil, details: nil)
    AdminAction.create!(
      :actor_id     => actor_id,
      :actor_label  => actor_label,
      :action       => action.to_s,
      :target_type  => target&.class&.name,
      :target_id    => target&.id,
      :target_label => AdminAction.label_for(target),
      :details      => details
    )
  end
end
