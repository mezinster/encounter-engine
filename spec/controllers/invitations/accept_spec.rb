# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe InvitationsController, "#accept", type: :controller do
  describe "when recepient attempts to accept the invitation" do
    before :each do
      @recepient = create_user
      @invitation = create_invitation :for => @recepient
      create_invitation :for => @recepient

      perform_request :as_user => @recepient
    end

    it "redirects to dashboard"

    it "deletes all the invitations sent to user" do
      Invitation.for(@recepient).count.should == 0
    end

    it "makes invited user member of the team" do
      @recepient.reload
      @recepient.team.should_not be_nil
      @recepient.team.id.should == @invitation.to_team.id
    end
  end

  # The reachable form of the captainless-team crash: #accept is gated on
  # being the RECIPIENT, not on the team having a captain, and the mailer
  # fires after the join and after the invitation row is deleted. Before the
  # guard in NotificationMailer this raised NoMethodError with the user
  # already joined and the invitation already gone -- a partial commit plus
  # an error page, with reject_rest_of_invitations never reaching.
  describe "when the invitation's team has no captain" do
    before :each do
      @recepient = create_user
      @team = create_team
      @invitation = create_invitation :for => @recepient, :from => @team
    end

    it "joins the user and completes without raising" do
      expect { perform_request :as_user => @recepient }.not_to raise_error

      expect(@recepient.reload.team).to eq(@team)
      expect(Invitation.find_by(:id => @invitation.id)).to be_nil
      expect(response).to redirect_to(dashboard_path)
    end
  end

  describe "when captain (sender) attempts to accept the invitation" do
    before :each do
      @captain = create_user
      team = create_team :captain => @captain
      @invitation = create_invitation :for => create_user, :from => team
    end

    it "raises Unauthorized" do
      assert_unauthorized { perform_request :as_user => @captain }
    end

    it "does not delete any invitation" do
      assert_does_not_delete_invitation { perform_request :as_user => @captain }
    end
  end

  describe "when other logged in user attempts to accept the invitation" do
    before :each do
      @some_user = create_user
      @invitation = create_invitation
    end

    it "raises Unauthorized" do
      assert_unauthorized { perform_request :as_user => @some_user }
    end

    it "does not delete any invitation" do
      assert_does_not_delete_invitation { perform_request :as_user => @some_user }
    end
  end

  describe "when guest attempts to accept the invitation" do
    before :each do
      @invitation = create_invitation
    end

    it "raises Unauthenticated" do
      assert_unauthenticated { perform_request }
    end

    it "does not delete any invitation" do
      assert_does_not_delete_invitation { perform_request }
    end
  end

  def assert_does_not_delete_invitation(&block)
    expect(&block).not_to change(Invitation, :count)
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    post :accept, params: { id: @invitation.id }
    response
  end
end
