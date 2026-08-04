# -*- encoding : utf-8 -*-
require "rails_helper"

# #edit already scoped @user to current_user (never took an id from the
# request), so it was never exploitable the way #update was. It gets
# require_authentication! here purely for robustness: without it, a guest's
# GET /users/edit set @user to nil (current_user is nil) and 500'd in
# form_for @user, instead of getting a clean redirect to the login page --
# see task-S-report.md for the full reasoning.
RSpec.describe UsersController, "#edit", type: :controller do
  before :each do
    @user = create_user
  end

  it "raises Unauthenticated exception for a guest" do
    assert_unauthenticated { perform_request }
  end

  it "shows the signed-in user their own edit form, regardless of the id in the route" do
    other_user = create_user
    perform_request(:as_user => @user, :id => other_user.id)

    expect(response).to have_http_status(:success)
    expect(assigns(:user)).to eq(@user)
  end

  def perform_request(opts = {})
    session[:user_id] = opts[:as_user]&.id
    get :edit, params: { id: opts[:id] || @user.id }
    response
  end
end
