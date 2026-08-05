require "rails_helper"

# The four admin screens live at paths that are linked from nowhere else: the
# console links onward to its siblings, but only once you have found the
# console. This puts them in the left menu, which renders on every page.
describe "the admin section of the left menu", type: :request do
  let(:ordinary)   { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "shows a superadmin every admin path" do
    sign_in(superadmin)

    get dashboard_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("layout.left_menu.administration"))
    [ admin_dashboard_path, admin_games_path, admin_users_path, admin_audit_index_path ].each do |path|
      expect(response.body).to include(%(href="#{path}"))
    end
  end

  # The load-bearing half. The menu renders on every page for every signed-in
  # user, so a missing guard would advertise the whole admin surface to the
  # players it is meant to be invisible to. The endpoints would still refuse
  # them, but "refused" and "never offered" are different products.
  it "shows an ordinary user none of them" do
    sign_in(ordinary)

    get dashboard_path

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(I18n.t("layout.left_menu.administration"))
    [ admin_dashboard_path, admin_games_path, admin_users_path, admin_audit_index_path ].each do |path|
      expect(response.body).not_to include(%(href="#{path}"))
    end
  end

  # current_user is nil here, so a guard written as current_user.superadmin?
  # outside the logged_in? branch would raise NoMethodError on every public
  # page -- the login screen included, locking everyone out.
  it "does not raise for an anonymous visitor" do
    get login_path

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(I18n.t("layout.left_menu.administration"))
  end
end
