require "rails_helper"

describe "the UI shell", type: :request do
  it "boots with a resolved theme and links the token stylesheet" do
    get login_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("/stylesheets/tokens.css")
    # The boot script must run before first paint, inline in <head>, or the
    # page flashes the wrong theme on every load.
    expect(response.body).to include("/javascripts/theme.js")
  end

  it "offers a theme toggle" do
    get login_path

    expect(response.body).to include('id="theme-toggle"')
  end

  describe "the navigation drawer" do
    let(:user) { create_user }

    def sign_in(u)
      put login_path, :params => { :email => u.email, :password => "1234" }
    end

    it "renders the menu inside a labelled drawer" do
      sign_in(user)

      get dashboard_path

      expect(response.body).to include('id="drawer"')
      expect(response.body).to include('id="drawer-toggle"')
    end

    # A drawer that only opens with JavaScript is a site that does not work
    # without JavaScript -- including the login page. The checkbox pattern
    # below opens it with CSS alone; drawer.js only adds niceties.
    it "keeps the menu reachable with no JavaScript" do
      sign_in(user)

      get dashboard_path

      expect(response.body).to include('id="drawer-state"')
      expect(response.body).to include(dashboard_path)
    end
  end
end
