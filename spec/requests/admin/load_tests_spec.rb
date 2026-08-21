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
  # design -- see the comment on Admin::LoadTestsController#store_manifest and
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

  # store_manifest writes to a fixed, predictable path (Dir.tmpdir/<cohort
  # id>.json) with O_EXCL, so a pre-existing file there -- a leftover from an
  # earlier rake seed under the same id, most plausibly -- makes the write
  # raise Errno::EEXIST. seed! has already committed the cohort to the
  # database by that point. The controller must not let that turn into a 500
  # that leaves the cohort both live and unrecorded: the audit entry has to
  # be written, and the operator has to be told the cohort id so they can
  # still find and tear it down.
  it "records the seed and redirects, rather than 500ing, when the manifest write collides with an existing file" do
    sign_in(superadmin)
    stale_path = File.join(Dir.tmpdir, "lt-test-a.json")
    File.write(stale_path, "stale")

    begin
      expect {
        post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")
      }.to change(Team, :count).by(2)

      expect(response).to redirect_to(admin_load_test_path)
      expect(AdminAction.newest_first.first.action).to eq("load_test_seed")
    ensure
      File.delete(stale_path) if File.exist?(stale_path)
    end
  end

  # The manifest holds a live password per seeded captain and measures ~20 KB at
  # 120 teams, against a 4096-byte cookie. Putting it in the session would both
  # overflow and ship production credentials to the browser on every request.
  it "keeps the manifest itself out of the session, storing only a path" do
    sign_in(superadmin)

    post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")

    expect(session[:load_test_manifest]).to be_nil
    expect(session[:load_test_manifest_path]).to be_present
    expect(session[:load_test_manifest_path]).not_to include("@loadtest.invalid")
  end

  it "offers the manifest as a download after seeding" do
    sign_in(superadmin)
    post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")

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

  # File.unlink can fail for reasons other than "the file is already gone" --
  # permissions, a read-only remount, anything SystemCallError covers -- and
  # the old exist?/unlink pair was a TOCTOU race on top of that (/tmp is
  # exactly where a cleaner or a container restart intervenes between the two
  # calls). Seeder.teardown! has already committed the deletion by the time
  # the manifest cleanup runs, so a raise there must not turn a successful
  # teardown into a 500 with no audit record of who did it. Stubs only the
  # ONE call with this specific path -- and_call_original on the general stub
  # keeps every other File.unlink call in the request (Rails internals
  # included) working normally.
  it "records the teardown and redirects, rather than 500ing, when the manifest cannot be removed" do
    sign_in(superadmin)
    post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")
    manifest_path = session[:load_test_manifest_path]

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
