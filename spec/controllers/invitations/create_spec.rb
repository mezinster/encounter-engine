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

    # TODO(Task 10): app/mailers/notification_mailer.rb is still the
    # pre-port Merb::MailController -- referencing NotificationMailer from
    # Rails raises NameError (uninitialized constant Merb), so
    # InvitationsController#create no longer sends this email (see the four
    # TODO(Task 10) comments in app/controllers/invitations_controller.rb:
    # lines 20-25, 38-39, 47-48, 70-72). Written against ActionMailer::Base's
    # real API (not the old Merb::Mailer.deliveries/assert_sends_email,
    # which no longer exist) so that once Task 10 ports the mailer and
    # restores the controller call, this either passes for real or fails
    # loudly -- it will not stay silently green if any of the four TODO
    # sites gets missed.
    it "sends a notification to invited user by email" do
      pending "NotificationMailer is not yet ported to ActionMailer (Task 10)"

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
