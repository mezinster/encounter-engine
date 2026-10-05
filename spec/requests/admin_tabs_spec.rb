require "rails_helper"

# The admin section tabs. Rendered from the application layout for every
# admin/* controller, so this visits every admin GET page rather than trusting
# that: a page that renders without the bar, or marks the wrong section, fails
# here. Add a row to PAGES when an admin page is added.
describe "the admin section tabs", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game) { create_game(:author => superadmin) }
  let(:team) { create_team(:captain => create_user) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def tabs
    Nokogiri::HTML(response.body).at_css("nav.admin-tabs")
  end

  PAGES = {
    "dashboard"         => [ :dashboard,  -> { admin_dashboard_path } ],
    "games list"        => [ :games,      -> { admin_games_path } ],
    "game entries"      => [ :games,      -> { admin_game_entries_path(game) } ],
    "users list"        => [ :users,      -> { admin_users_path } ],
    "user page"         => [ :users,      -> { admin_user_path(superadmin) } ],
    "teams list"        => [ :teams,      -> { admin_teams_path } ],
    "team adjustment"   => [ :teams,      -> { new_admin_team_adjustment_path(:team_id => team.id) } ],
    "audit log"         => [ :audit,      -> { admin_audit_index_path } ],
    "settings"          => [ :settings,   -> { admin_settings_path } ],
    "load test"         => [ :load_test,  -> { admin_load_test_path } ],
    "styleguide"        => [ :styleguide, -> { admin_styleguide_path } ]
  }.freeze

  PAGES.each do |name, (section, path)|
    it "renders on the #{name}, marking #{section}" do
      sign_in(superadmin)
      get instance_exec(&path)

      expect(response).to have_http_status(:ok)
      expect(tabs).not_to be_nil
      expect(tabs.css("a").size).to eq(8)
      current = tabs.css("a[aria-current='page']")
      expect(current.size).to eq(1)
      expect(current.first["href"]).to eq(instance_exec(&PAGES.values.find { |s, _| s == section }.last))
    end
  end

  it "links all eight sections, in order" do
    sign_in(superadmin)
    get admin_dashboard_path

    expect(tabs.css("a").map { |a| a["href"] }).to eq([
      admin_dashboard_path, admin_games_path, admin_users_path, admin_teams_path,
      admin_audit_index_path, admin_settings_path, admin_load_test_path, admin_styleguide_path
    ])
    expect(tabs["aria-label"]).to eq("Разделы администрирования")
  end

  # The bar lives in the shared layout now, so its guard is the controller path.
  it "is absent from a non-admin page, even for a superadmin" do
    sign_in(superadmin)
    get dashboard_path

    expect(response).to have_http_status(:ok)
    expect(tabs).to be_nil
  end

  it "is absent for an ordinary user's pages" do
    sign_in(create_user)
    get dashboard_path

    expect(tabs).to be_nil
  end
end
