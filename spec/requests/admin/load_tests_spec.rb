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
end
