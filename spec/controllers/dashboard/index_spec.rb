# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe DashboardController, "#index", type: :controller do
  describe "when guest enters the dashboard" do
    it "raises Unauthenticated exception" do
      assert_unauthenticated { perform_request }
    end
  end

  describe "when logged in user enters the dashboard" do
    before :each do
      user = create_user
      @response = perform_request :as_user => user
    end

    it "responds successfully" do
      expect(@response).to have_http_status(:success)
    end
  end

  describe "when invitations exists" do
    before :each do
      user = create_user

      @expected_invitations = []
      @expected_invitations << create_invitation(:for => user)
      @expected_invitations << create_invitation(:for => user)
      create_invitation :for => create_user

      @response = perform_request :as_user => user
    end

    it "assigns invitations for the current user" do
      # Scopes return an ActiveRecord::Relation rather than an Array since
      # Rails 3, and Relation does not include Enumerable. What matters is
      # that it yields the right invitations, which is asserted below.
      assigns(:invitations).length.should == @expected_invitations.length
      assigns(:invitations).each do |invitation|
        expected_invitation?(invitation).should be_truthy
      end
    end

    def expected_invitation?(invitation)
      @expected_invitations.each do |expected_invitaion|
        return true if expected_invitaion.id == invitation.id
      end
      return false
    end
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    get :index
    response
  end
end
