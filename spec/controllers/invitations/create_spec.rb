# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe InvitationsController, "#create", type: :controller do
  describe "security filters" do
    describe "captain attempts to invite a new user" do
      before :each do
        @captain = create_user
        @team = create_team :captain => @captain
      end

      it "does not raise any error" do
        expect do
          perform_request :as_user => @captain
        end.not_to raise_error
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
    # InvitationsController#create no longer sends this email (see the
    # TODO comment there). This example depended on Merb::Mailer.deliveries,
    # which no longer exists either. Un-pend once Task 10 ports the mailer
    # and the controller call is restored.
    it "sends a notification to invited user by email" do
      pending "NotificationMailer is not yet ported to ActionMailer (Task 10)"

      assert_sends_email { perform_request({ :as_user => @captain }, @params) }

      Merb::Mailer.deliveries.last.to.first.should == @user.email
      Merb::Mailer.deliveries.last.text.should match(/Вас пригласили вступить в команду #{@team.name}/)
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
