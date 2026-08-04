# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe InvitationsController, "#create", type: :controller do
  describe "security filters" do
    describe "captain attempts to invite a new user" do
      before :each do
        @captain = create_user
        @team = create_team :captain => @captain
        @invited_user = create_user
      end

      # Under Merb this asserted `should_not raise_error`, which passed
      # whether ensure_team_captain allowed or denied the request (a denial
      # now redirects/401s instead of raising, so that assertion would pass
      # either way and prove nothing). Asserting the actual redirect proves
      # the captain was let through the security filter, not just that
      # nothing blew up.
      it "is not rejected by the security filters" do
        perform_request({ :as_user => @captain },
                         { :invitation => { :recepient_nickname => @invited_user.nickname } })
        expect(response).to redirect_to(new_invitation_path)
      end
    end

    describe "a regular team member attepmts to invite user" do
      before :each do
        captain = create_user
        @member = create_user
        create_team :captain => captain, :members => [@member]
      end

      it "raises Unauthorized exception" do
        assert_unauthorized { perform_request :as_user => @member }
      end
    end

    describe "a guest attempts to create an invitation" do
      it "raises Unauthenticated exception" do
        assert_unauthenticated { perform_request }
      end
    end
  end

  describe "regular case, captain invites a new user" do
    before :each do
      @user = create_user
      @captain = create_user
      @team = create_team :captain => @captain
      @params = { :invitation => { :recepient_nickname => @user.nickname } }
    end

    it "redirects" do
      response = perform_request({ :as_user => @captain }, @params)
      response.status.should == 302
    end

    it "creates an invitation" do
      expect do
        perform_request({ :as_user => @captain }, @params)
      end.to change(Invitation, :count).by(1)
    end

    # Task 10 ported NotificationMailer to ActionMailer and restored the
    # four TODO(Task 10) call sites in app/controllers/invitations_controller.rb
    # (lines 20-25, 38-39, 47-48, 70-72), including this one
    # (InvitationsController#create). Un-pending this now exercises the real
    # call site end-to-end.
    it "sends a notification to invited user by email" do
      expect do
        perform_request({ :as_user => @captain }, @params)
      end.to change(ActionMailer::Base.deliveries, :size).by(1)

      mail = ActionMailer::Base.deliveries.last
      mail.to.should include(@user.email)
      mail.body.encoded.should match(/Вас пригласили вступить в команду #{@team.name}/)
    end

    it "assigns captain team as invitation target team" do
      perform_request({ :as_user => @captain }, @params)

      assigns(:invitation).to_team.id.should == @team.id
    end

    it "finds proper user by email" do
      perform_request({ :as_user => @captain }, @params)

      assigns(:invitation).for_user.id.should == @user.id
    end
  end

  def perform_request(opts={}, params={})
    session[:user_id] = opts[:as_user]&.id
    post :create, params: params
    response
  end
end
