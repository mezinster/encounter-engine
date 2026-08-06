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
    # Two-minors cleanup, cheap-minor 1 of the whole-branch review: tightened
    # from `not_to have_http_status(:ok)`. An anonymous visitor hits
    # require_authentication! before require_superadmin! ever runs, so this
    # is Authentication::Unauthenticated (redirect to login), not
    # Authentication::Unauthorized (401) -- verified live. The signed-in
    # case below does reach require_superadmin! and gets the 401.
    it "refuses an anonymous visitor" do
      get admin_dashboard_path
      expect(response).to have_http_status(:found)
      expect(response).to redirect_to(login_path)
    end

    it "refuses an ordinary signed-in user" do
      sign_in(ordinary)
      get admin_dashboard_path
      expect(response).to have_http_status(:unauthorized)
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

  describe "the users list" do
    # Same reasoning as the stats screen's anonymous case above: anonymous
    # never reaches require_superadmin!.
    it "refuses an anonymous visitor" do
      get admin_users_path
      expect(response).to have_http_status(:found)
      expect(response).to redirect_to(login_path)
    end

    it "refuses an ordinary signed-in user" do
      sign_in(ordinary)
      get admin_users_path
      expect(response).to have_http_status(:unauthorized)
    end

    it "shows every user's identity and email to a superadmin" do
      other = create_user
      sign_in(superadmin)

      get admin_users_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(other.nickname)
      expect(response.body).to include(other.email)
    end

    # The contact details a player gave in order to play, not to be browsed.
    # They exist on the detail page; the point is that reading all of them
    # takes deliberate clicks.
    it "does not put contact details in the list" do
      other = create_user
      other.update!(:phone_number => "+995555123456")
      sign_in(superadmin)

      get admin_users_path

      expect(response.body).not_to include("+995555123456")
    end

    # This N+1 has been written into two consecutive plans on this project and
    # shipped once. It gets a test rather than a comment.
    it "keeps the query count flat as the number of users grows" do
      sign_in(superadmin)

      2.times { u = create_user; u.update!(:team => create_team) }
      small = count_queries { get admin_users_path }

      8.times { u = create_user; u.update!(:team => create_team) }
      large = count_queries { get admin_users_path }

      expect(large).to eq(small)
    end
  end

  describe "the user detail page" do
    it "refuses an ordinary signed-in user" do
      sign_in(ordinary)
      get admin_user_path(create_user)
      expect(response).to have_http_status(:unauthorized)
    end

    it "shows contact details to a superadmin" do
      other = create_user
      other.update!(:phone_number => "+995555123456",
                    :instagram => "@someone", :telegram_id => "@somebody", :on_signal => true)
      sign_in(superadmin)

      get admin_user_path(other)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("+995555123456")
      expect(response.body).to include("someone")
      expect(response.body).to include("somebody")
      expect(response.body).to include(I18n.t("messengers.signal"))
    end
  end

  # Not because anyone would add them deliberately, but because a future
  # `<%= user.attributes %>` debugging line would leak them silently.
  describe "password material" do
    it "never appears on any reporting screen" do
      other = create_user
      sign_in(superadmin)

      [ admin_dashboard_path, admin_users_path, admin_user_path(other) ].each do |path|
        get path
        expect(response.body).not_to include(other.crypted_password.to_s) if other.crypted_password.present?
        expect(response.body).not_to include(other.salt.to_s) if other.salt.present?
      end
    end
  end
end
