require "rails_helper"

describe "the load-test console", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:source) do
    game = create_game
    create_level(:game => game, :correct_answer => "aaa")
    game
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def seed_params(confirm:, cohort: "lt-test-a")
    { :source_game_id => source.id, :teams => 2,
      :cohort_id => cohort, :confirm_cohort_id => confirm }
  end

  # The manifest path is fixed and predictable (cohort id -> filename), by
  # design -- see the comment on Admin::LoadTestsController#manifest_path and
  # the matching hazard documented in lib/tasks/load_test.rake. Real usage
  # never collides because only one cohort exists at a time; this spec file
  # reuses the same cohort id "lt-test-a" across several examples in one
  # process, so it has to clear any leftover file itself or the second seed
  # in the same run hits the real, documented Errno::EEXIST from
  # LoadTest::ManifestFile.write!'s O_EXCL.
  before do
    stale = File.join(Dir.tmpdir, "lt-test-a.json")
    File.delete(stale) if File.exist?(stale)
  end

  # #seed now spawns a background Thread (see the controller's own comment on
  # why: ten minutes in a Puma thread was the entire 2026-08-21 incident).
  # Every example below except the one specifically about the ordering runs
  # that block INLINE instead of racing a real thread, by stubbing the one
  # seam the controller calls through -- #run_in_background -- to invoke its
  # block synchronously rather than spawning anything. This is what
  # "run the thread inline in specs" means throughout this file.
  before do
    allow_any_instance_of(Admin::LoadTestsController)
      .to receive(:run_in_background) { |_, &block| block.call }
  end

  it "refuses an ordinary signed-in user" do
    sign_in(create_user)
    get admin_load_test_path
    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses an operator who is not a superadmin" do
    operator = create_user
    operator.update!(:is_operator => true)
    sign_in(operator)

    get admin_load_test_path

    expect(response).to have_http_status(:unauthorized)
  end

  it "shows the screen to a superadmin" do
    sign_in(superadmin)
    get admin_load_test_path
    expect(response).to have_http_status(:ok)
  end

  # The typed confirmation must be ENFORCED, not merely rendered. A button that
  # creates hundreds of production accounts must not be one misclick.
  it "creates nothing when the typed cohort id does not match" do
    sign_in(superadmin)
    # Force `source`'s memoization NOW, outside the assertion window below.
    # build_level's default :game value is `create_game` in a hash literal,
    # evaluated eagerly even though `create_level(:game => game, ...)` always
    # overrides it -- so the FIRST access to `source` incidentally creates an
    # extra throwaway game (and its author) as a side effect of test setup,
    # nothing to do with this controller. Accessed lazily inside the `expect`
    # block below (via seed_params -> source.id), that incidental user shows
    # up as a false-positive "creates nothing" failure.
    source

    expect {
      post admin_load_test_seed_path, :params => seed_params(:confirm => "wrong")
    }.not_to change(User, :count)
  end

  it "seeds when the typed cohort id matches" do
    sign_in(superadmin)

    expect {
      post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")
    }.to change(Team, :count).by(2)
  end

  # Proves the controller returns before the seed itself has run, rather than
  # merely running it fast -- the point of moving it off the request thread
  # at all. #run_in_background is stubbed here (overriding the file-level
  # before block above) to CAPTURE its block instead of calling it, so the
  # response can be inspected before anything the seed does exists.
  it "redirects immediately, saying seeding has started, before the seed itself has run" do
    sign_in(superadmin)
    source # see the eager-evaluation comment on the earlier mismatch example
    captured = nil
    allow_any_instance_of(Admin::LoadTestsController)
      .to receive(:run_in_background) { |_, &block| captured = block }

    expect {
      post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")
    }.not_to change(Team, :count)

    expect(response).to redirect_to(admin_load_test_path)
    follow_redirect!
    # The literal Russian "seeding started" notice, not "cohort created" --
    # the whole point is that this redirect happens before seeding runs, so
    # it cannot yet know whether the cohort will exist.
    expect(response.body).to include("Посев запущен.")

    expect { captured.call }.to change(Team, :count).by(2)
  end

  it "seeds in a live (production-shaped) environment when the typed cohort id matches" do
    allow(LoadTest).to receive(:live?).and_return(true)
    sign_in(superadmin)

    expect {
      post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")
    }.to change(Team, :count).by(2)

    expect(response).to redirect_to(admin_load_test_path)
    follow_redirect!
    # The literal Russian success notice, not a guard refusal -- see the
    # comment further down on why this file asserts literal strings rather
    # than comparing against I18n.t.
    expect(response.body).to include("Посев запущен.")
  end

  it "refuses to seed in a live (production-shaped) environment when the typed cohort id does not match" do
    allow(LoadTest).to receive(:live?).and_return(true)
    sign_in(superadmin)
    source # see the eager-evaluation comment on the earlier mismatch example

    expect {
      post admin_load_test_seed_path, :params => seed_params(:confirm => "wrong")
    }.not_to change(User, :count)
  end

  # store_manifest used to write to a fixed, predictable path
  # (Dir.tmpdir/<cohort id>.json) with O_EXCL, so a pre-existing file there --
  # a leftover from an earlier rake seed under the same id, most plausibly --
  # made the write raise Errno::EEXIST. seed! has already committed the
  # cohort to the database by that point, and the AdminAction has already
  # been recorded. Now that seeding runs in a background thread, a raise
  # there cannot turn into a 500 or an alert on the redirect the way it once
  # could -- there is no request left to carry it -- so it goes through the
  # same Rails.cache path any other thread failure does (see
  # Admin::LoadTestsController#perform_seed), and the console surfaces it on
  # the next page load instead.
  it "records the seed and surfaces the manifest-collision message, rather than losing the cohort" do
    sign_in(superadmin)
    stale_path = File.join(Dir.tmpdir, "lt-test-a.json")
    File.write(stale_path, "stale")

    begin
      expect {
        post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")
      }.to change(Team, :count).by(2)

      expect(response).to redirect_to(admin_load_test_path)
      expect(AdminAction.newest_first.first.action).to eq("load_test_seed")

      get admin_load_test_path
      expect(response.body)
        .to include("Когорта lt-test-a создана, но манифест не записан: файл уже существует.")

      # Shown once, then cleared -- a resolved failure must not keep
      # reappearing on every later visit to the console.
      get admin_load_test_path
      expect(response.body).not_to include("манифест не записан")
    ensure
      File.delete(stale_path) if File.exist?(stale_path)
    end
  end

  # Production bug: a source game whose GameCloner-produced clone fails one of
  # Game's own validations (originally: available_locales inherited from the
  # source, declaring languages the clone has zero content_translations for --
  # see lib/load_test/game_cloner.rb) reached the operator as Rails' raw 422
  # error page, because #seed did not rescue ActiveRecord::RecordInvalid. On a
  # console whose entire point is to be safer than the command line, that is
  # the wrong failure mode.
  #
  # GameCloner itself is fixed now (available_locales/access_mode are no
  # longer copied from the source), so the ORIGINAL failure can no longer be
  # reproduced end-to-end through this controller -- which is the point of the
  # fix. To pin the controller's OWN behaviour (rescue and surface the
  # underlying messages) independently of whatever GameCloner happens to
  # guarantee today, this stubs LoadTest::Seeder.new to return a double whose
  # #seed! raises ActiveRecord::RecordInvalid directly, carrying a record with
  # a known, deterministic error message.
  it "surfaces the validation messages via the console, rather than raising, when the clone is invalid" do
    sign_in(superadmin)
    source # see the eager-evaluation comment on the earlier mismatch example

    invalid_record = Game.new
    invalid_record.errors.add(:base, "boom, специально невалидная запись")
    seeder = instance_double(LoadTest::Seeder)
    allow(LoadTest::Seeder).to receive(:new).and_return(seeder)
    allow(seeder).to receive(:seed!).and_raise(ActiveRecord::RecordInvalid.new(invalid_record))

    expect {
      post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")
    }.not_to change(Team, :count)

    expect(response).to redirect_to(admin_load_test_path)
    get admin_load_test_path
    expect(response.body).to include("boom, специально невалидная запись")
  end

  # Errors are surfaced, not swallowed: a generic failure inside the thread
  # (anything that is not one of the three specifically-translated exception
  # classes -- CohortPresent, AlreadySeeding, RecordInvalid) still has to
  # reach the operator, not vanish because there is no request left to carry
  # a flash.
  it "surfaces a generic failure via the console rather than losing it silently" do
    sign_in(superadmin)
    source # see the eager-evaluation comment on the earlier mismatch example

    seeder = instance_double(LoadTest::Seeder)
    allow(LoadTest::Seeder).to receive(:new).and_return(seeder)
    allow(seeder).to receive(:seed!).and_raise(StandardError, "kaboom, совершенно неожиданно")

    post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")

    get admin_load_test_path
    expect(response.body).to include("Не удалось создать когорту")
  end

  # Attributed from the thread, not from the request -- current_user is
  # request state and the thread outlives the request. See
  # Admin::LoadTestsController#perform_seed and #write_admin_action.
  it "attributes the seed's audit entry to the actor who triggered it" do
    sign_in(superadmin)

    post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")

    entry = AdminAction.newest_first.first
    expect(entry.action).to eq("load_test_seed")
    expect(entry.actor_label).to eq(superadmin.nickname)
  end

  # #status[:seeding] is derived from the lock (LoadTest::Seeder#seed! holds
  # it for the whole method), not a new table -- see the class comment. Only
  # the RENDERING is under test here; the lock itself has its own spec in
  # spec/lib/load_test/seeder_spec.rb.
  it "shows a seeding-in-progress state instead of offering to seed again" do
    sign_in(superadmin)
    allow(LoadTest::Seeder).to receive(:status)
      .and_return(:cohort_id => nil, :users => 0, :seeding => true)

    get admin_load_test_path

    expect(response.body).to include("Идёт посев когорты")
    # Neither form is offered while a seed is already in flight -- offering
    # the seed form here is exactly the double-submit that caused the
    # 2026-08-21 incident.
    expect(response.body).not_to include('name="teams"')
  end

  it "downloads the manifest without ever having stored its path in the session" do
    sign_in(superadmin)
    post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")

    expect(session[:load_test_manifest_path]).to be_nil

    get admin_load_test_manifest_path

    expect(response.headers["Content-Disposition"]).to include("attachment")
    expect(JSON.parse(response.body)["teams"].size).to eq(2)
  end

  it "tears the cohort down again" do
    sign_in(superadmin)
    post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")

    expect {
      post admin_load_test_teardown_path,
           :params => { :cohort_id => "lt-test-a", :confirm_cohort_id => "lt-test-a" }
    }.to change(Team, :count).by(-2)
  end

  # Same shape as the seed examples above: before this fix, guard! read
  # ENV["LOAD_TEST_CONFIRM"] directly, so teardown was exactly as unreachable
  # from the console in a live environment as seeding was.
  it "tears the cohort down in a live (production-shaped) environment when the typed cohort id matches" do
    sign_in(superadmin)
    post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")

    allow(LoadTest).to receive(:live?).and_return(true)

    expect {
      post admin_load_test_teardown_path,
           :params => { :cohort_id => "lt-test-a", :confirm_cohort_id => "lt-test-a" }
    }.to change(Team, :count).by(-2)
  end

  it "refuses to tear down in a live (production-shaped) environment when the typed cohort id does not match" do
    sign_in(superadmin)
    post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")

    allow(LoadTest).to receive(:live?).and_return(true)

    expect {
      post admin_load_test_teardown_path,
           :params => { :cohort_id => "lt-test-a", :confirm_cohort_id => "wrong" }
    }.not_to change(Team, :count)
  end

  # File.unlink can fail for reasons other than "the file is already gone" --
  # permissions, a read-only remount, anything SystemCallError covers -- and
  # the old exist?/unlink pair was a TOCTOU race on top of that (/tmp is
  # exactly where a cleaner or a container restart intervenes between the two
  # calls). Seeder.teardown! has already committed the deletion by the time
  # the manifest cleanup runs, so a raise there must not turn a successful
  # teardown into a 500 with no audit record of who did it. The path is
  # derived from the cohort id (#manifest_path), the same one #manifest and
  # perform_seed use -- there is no session entry to read it back from any
  # more. Stubs only the ONE call with this specific path -- and_call_original
  # on the general stub keeps every other File.unlink call in the request
  # (Rails internals included) working normally.
  it "records the teardown and redirects, rather than 500ing, when the manifest cannot be removed" do
    sign_in(superadmin)
    post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")
    manifest_path = File.join(Dir.tmpdir, "lt-test-a.json")

    allow(File).to receive(:unlink).and_call_original
    allow(File).to receive(:unlink).with(manifest_path).and_raise(Errno::EACCES)

    expect {
      post admin_load_test_teardown_path,
           :params => { :cohort_id => "lt-test-a", :confirm_cohort_id => "lt-test-a" }
    }.to change(Team, :count).by(-2)

    expect(response).to redirect_to(admin_load_test_path)
    expect(AdminAction.newest_first.first.action).to eq("load_test_teardown")
  end

  # cohort_id is written verbatim into a filesystem path (see
  # Admin::LoadTestsController::COHORT_ID's comment) and, inside the seeder,
  # into nicknames and e-mail local parts. Not remotely exploitable -- only a
  # superadmin reaches this action -- but a path-shaped id must still be
  # refused at the door rather than failing confusingly deep inside the
  # seeder's e-mail validation.
  it "creates nothing when the cohort id is not a safe slug" do
    sign_in(superadmin)
    source # see the eager-evaluation comment above -- keep it out of the window below

    expect {
      post admin_load_test_seed_path,
           :params => seed_params(:confirm => "../escape", :cohort => "../escape")
    }.not_to change(User, :count)
  end

  # The literal Russian, NOT include(I18n.t(...)). Asserting against I18n.t
  # passes even when the key is missing, because both sides resolve to the same
  # "translation missing" string -- a vacuous assertion.
  it "names the screen and warns that seeding writes real accounts" do
    sign_in(superadmin)

    get admin_load_test_path

    expect(response.body).to include("Нагрузочное тестирование")
    expect(response.body).to include("создаёт настоящие учётные записи")
  end

  it "reports that no cohort is present on a clean database" do
    sign_in(superadmin)

    get admin_load_test_path

    expect(response.body).to include("Когорта не создана")
  end
end
