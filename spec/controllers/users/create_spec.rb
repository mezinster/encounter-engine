# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe UsersController, "#create", type: :controller do
  describe "with valid data" do
    let(:params) do
      { user: { nickname: "valid#{rand(100000)}", email: "valid#{rand(100000)}@diesel.kg",
                password: "1234", password_confirmation: "1234" } }
    end

    it "creates a new user" do
      expect { perform_request(params) }.to change(User, :count).by(1)
    end

    it "logs the new user in" do
      perform_request(params)
      expect(session[:user_id]).to eq(User.last.id)
    end

    it "redirects to the dashboard" do
      perform_request(params)
      expect(response).to redirect_to(dashboard_path)
    end
  end

  describe "with invalid data" do
    let(:params) { { user: { nickname: "", email: "not-an-email", password: "1", password_confirmation: "2" } } }

    it "does not create a user" do
      expect { perform_request(params) }.not_to change(User, :count)
    end

    it "re-renders the signup form" do
      perform_request(params)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "strong parameters" do
    # user_params permits only nickname/email/password/password_confirmation
    # (see app/views/users/new.html.erb) -- signup must not let a request
    # attach the new account to a team.
    it "ignores an attempted team_id" do
      team = create_team
      params = { user: { nickname: "valid#{rand(100000)}", email: "valid#{rand(100000)}@diesel.kg",
                          password: "1234", password_confirmation: "1234", team_id: team.id } }

      perform_request(params)

      expect(User.last.team_id).to be_nil
    end
  end

  def perform_request(params = {})
    post :create, params: params
    response
  end
end
