# -*- encoding : utf-8 -*-
#
# The console front door onto LoadTest::Seeder. It does not reimplement any of
# it: a screen holding its own copy of the seeding logic would drift from the
# rake task, and the two are used on the same night by the same person.
class Admin::LoadTestsController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!

  def show
    @status = LoadTest::Seeder.status
    @games  = Game.order(:name)
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
    # process -- see the Puma/rake split in lib/load_test.rb).
    LoadTest.guard!(cohort_id, :confirmation => params[:confirm_cohort_id])
    manifest = LoadTest::Seeder.new(
      :source_game => Game.find(params[:source_game_id]),
      :teams       => params[:teams],
      :cohort_id   => cohort_id,
      :base_url    => request.base_url
    ).seed!

    # AFTER the change has landed, and with details: "someone ran a load test"
    # is not an audit trail. AdminAudit records by an explicit call per action
    # on purpose -- see the concern's own comment. Recorded HERE, immediately
    # once seed! returns, rather than after store_manifest below: seed! is
    # what touched the database, and a manifest-write failure (predictable
    # path, O_EXCL -- see store_manifest's comment) must not be able to leave
    # a committed cohort with no audit record of who created it.
    record_admin_action("load_test_seed", Game.find(manifest[:game_id]),
                        "cohort=#{cohort_id}, source=#{params[:source_game_id]}, " \
                        "teams=#{manifest[:teams].size}")

    begin
      store_manifest(manifest)
    rescue Errno::EEXIST
      # The cohort is live AND recorded above -- only the credentials file is
      # missing. Name the cohort so the operator can still find and tear down
      # what was just created, rather than 500ing and leaving them with
      # nothing to go on.
      return redirect_to admin_load_test_path,
                         :alert => t("admin.load_test.manifest_exists", :cohort => cohort_id)
    end

    redirect_to admin_load_test_path, :notice => t("admin.load_test.seeded")
  # Translated keys, never e.message: LoadTest::Seeder::CohortPresent's
  # message interpolates whatever LoadTest::Seeder.status[:cohort_id] returns
  # (see that class), and LoadTest::Refused's is a hardcoded English sentence
  # meant for a rake operator's terminal -- neither belongs verbatim on a
  # screen where every other string is translated. cohort_id here is the id
  # the operator just typed, the same value either exception is about.
  rescue LoadTest::Seeder::CohortPresent
    redirect_to admin_load_test_path,
               :alert => t("admin.load_test.cohort_present", :cohort => cohort_id)
  rescue LoadTest::Refused
    redirect_to admin_load_test_path, :alert => t("admin.load_test.refused")
  # The clone (or one of the levels under it) failed a model validation --
  # e.g. GameCloner producing a Game whose available_locales declares a
  # language it has no translations for. seed! rolls that back inside its own
  # transaction (Game.transaction in GameCloner#call), so nothing is left
  # half-created; the operator just needs to see WHY, which e.record.errors
  # carries and a bare 500 page would not. This is a console whose whole job
  # is to be safer than the command line, so a bad clone has to read back as
  # an alert with the real validation messages, not Rails' default error page.
  rescue ActiveRecord::RecordInvalid => e
    redirect_to admin_load_test_path,
               :alert => t("admin.load_test.invalid_clone",
                           :errors => e.record.errors.full_messages.join("; "))
  end

  def teardown
    cohort_id = params[:cohort_id].to_s
    return refuse unless confirmed?(cohort_id)
    return refuse_invalid unless valid_cohort_id?(cohort_id)

    # See the matching comment in #seed.
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
    # already succeeded.
    path = session.delete(:load_test_manifest_path)
    begin
      File.unlink(path) if path.present?
    rescue Errno::ENOENT
      # Already gone -- nothing to do.
    rescue SystemCallError => e
      Rails.logger.warn("[load_test] could not remove manifest #{path}: #{e.class}")
    end

    redirect_to admin_load_test_path, :notice => t("admin.load_test.torn_down")
  rescue LoadTest::Refused
    redirect_to admin_load_test_path, :alert => t("admin.load_test.refused")
  end

  def manifest
    path = session[:load_test_manifest_path]
    if path.blank? || !File.exist?(path)
      return redirect_to(admin_load_test_path, :alert => t("admin.load_test.no_manifest"))
    end

    send_data File.read(path), :filename => "load-test-manifest.json",
                               :type => "application/json", :disposition => "attachment"
  end

  private

  # A slug, not free text. cohort_id is written verbatim into a filesystem
  # path (Dir.tmpdir/#{cohort_id}.json -- see store_manifest) and, inside the
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

  # The PATH in the session, never the manifest itself -- and this is not a
  # preference, it is the only thing that works.
  #
  # This app uses Rails' default COOKIE session store (nothing in config/ sets
  # another), so anything put in the session is serialised into a 4096-byte
  # cookie. A 120-team manifest measures 20,365 bytes: the seed would commit to
  # the database and then raise ActionDispatch::Cookies::CookieOverflow on the
  # redirect, leaving a live cohort in production and the operator holding
  # nothing -- the same stranding failure as the EEXIST case in the rake task.
  #
  # It is also the wrong place on its own terms: the manifest holds a live
  # password for every seeded captain, and a cookie is sent to the browser and
  # back on every subsequent request.
  #
  # LoadTest::ManifestFile.write! already creates the file atomically at 0600
  # and refuses any path under Rails.root, so the console reuses it rather than
  # growing a second copy of that logic. The file lives in the container's
  # temporary directory and does not survive a deploy, which is the right
  # lifetime for credentials: if it is lost, tear the cohort down and re-seed.
  def store_manifest(manifest)
    session[:load_test_manifest_path] =
      LoadTest::ManifestFile.write!(manifest,
                                    :path => File.join(Dir.tmpdir, "#{manifest[:cohort_id]}.json"))
  end
end
