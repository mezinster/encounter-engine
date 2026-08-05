require "rails_helper"

describe "superadmin reporting", type: :request do
  let(:ordinary)   { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  # config/routes.rb maps GET /login to sessions#new (the form) and PUT /login
  # to sessions#update. create_user sets the password "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  describe "the stats screen" do
    it "refuses an anonymous visitor" do
      get admin_dashboard_path
      expect(response).not_to have_http_status(:ok)
    end

    it "refuses an ordinary signed-in user" do
      sign_in(ordinary)
      get admin_dashboard_path
      expect(response).not_to have_http_status(:ok)
    end

    it "shows a superadmin the counts" do
      create_game(:is_draft => true)
      sign_in(superadmin)

      get admin_dashboard_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("admin.dashboard.show.title"))
      expect(response.body).to include(I18n.t("admin.dashboard.show.status.draft"))
    end
  end
end
