# -*- encoding : utf-8 -*-
#
# The console front door onto LoadTest::Seeder. It does not reimplement any of
# it: a screen holding its own copy of the seeding logic would drift from the
# rake task, and the two are used on the same night by the same person.
#
# Flash messages here are plain Russian string literals, NOT t() calls. Task 6
# owns this screen's i18n and its seven locale files; no admin.load_test.* key
# exists yet, and the test environment raises on a missing translation --
# calling t() here would turn every example that reaches these lines red.
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

    LoadTest.guard!(cohort_id)
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
                         :alert => "Когорта #{cohort_id} создана, но манифест не записан: файл уже существует."
    end

    redirect_to admin_load_test_path, :notice => "Когорта загружена"
  rescue LoadTest::Seeder::CohortPresent, LoadTest::Refused => e
    redirect_to admin_load_test_path, :alert => e.message
  end

  def teardown
    cohort_id = params[:cohort_id].to_s
    return refuse unless confirmed?(cohort_id)

    LoadTest.guard!(cohort_id)
    removed = LoadTest::Seeder.teardown!(cohort_id)
    # The credentials outlive the accounts otherwise.
    path = session.delete(:load_test_manifest_path)
    File.unlink(path) if path.present? && File.exist?(path)

    record_admin_action("load_test_teardown", nil,
                        "cohort=#{cohort_id}, rows=#{removed}")
    redirect_to admin_load_test_path, :notice => "Когорта удалена"
  rescue LoadTest::Refused => e
    redirect_to admin_load_test_path, :alert => e.message
  end

  def manifest
    path = session[:load_test_manifest_path]
    if path.blank? || !File.exist?(path)
      return redirect_to(admin_load_test_path, :alert => "Манифест недоступен")
    end

    send_data File.read(path), :filename => "load-test-manifest.json",
                               :type => "application/json", :disposition => "attachment"
  end

  private

  def confirmed?(cohort_id)
    cohort_id.present? && params[:confirm_cohort_id].to_s == cohort_id
  end

  def refuse
    redirect_to admin_load_test_path, :alert => "Идентификатор когорты не подтверждён"
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
