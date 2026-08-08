# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe LevelsController, "#create", type: :controller do
  describe "security filters" do
    describe "when the game author attempts to create a new level" do
      before :each do
        @author = create_user
        @game = create_game :author => @author
      end

      # Under Merb this asserted `should_not raise_error`, which passed
      # whether ensure_author allowed or denied the request -- a denial now
      # redirects/401s instead of raising, so that assertion proved nothing
      # about the security filter. Asserting the real redirect proves the
      # author was let through.
      it "is not rejected by the security filters" do
        perform_request({ :as_user => @author },
                         { :level => { :name => "L", :text => "T", :correct_answer => "A" } })
        expect(response).to redirect_to(game_level_path(@game, Level.last))
      end

      it "redirects to level profile"
    end

    describe "when any other user attempts to create a new level" do
      before :each do
        @user = create_user
        @game = create_game
      end

      it "raises Unauthorized exception" do
        assert_unauthorized { perform_request(:as_user => @user) }
      end
    end

    describe "when a guest attempts to create a new level" do
      before :each do
        @game = create_game :is_draft => false
      end

      it "raises Unauthorized exception" do
        assert_unauthorized { perform_request }
      end
    end
  end

  describe "when author entered correct data" do
    before :each do
      @author = create_user
      @game = create_game :author => @author
      @params = { :name => 'Test level', :text => 'Level text', :correct_answer => 'the answer' }
    end

    it "creates a new level" do
      expect do
        perform_request({ :as_user => @author }, { :level => @params })
      end.to change(Level, :count).by(1)
    end

    it "sets 'game' attribute of the level" do
      perform_request({ :as_user => @author }, { :level => @params })
      Level.last.game.id.should == @game.id
    end

    it "sets 'position' attribute" do
      perform_request({ :as_user => @author }, { :level => @params })
      Level.last.position.should == 1
    end

    describe "when author enters correct answer with redundant spaces"  do
      before :each do
        perform_request({ :as_user => @author }, { :level => @params.merge(:correct_answer => '  the answer   ') })
      end

      it "should strip them" do
        Level.last.questions.first.correct_answer.should == 'the answer'
      end
    end

    describe "when several levels are created" do
      before :each do
        perform_request({ :as_user => @author }, { :level => @params })
        @first_level = Level.last

        perform_request({ :as_user => @author }, { :level => @params })
        @second_level = Level.last

        @game = create_game :author => @author
        perform_request({ :as_user => @author }, { :level => @params })
        @first_level_in_other_game = Level.last
      end

      it "sets an 'position' incrementally within the game" do
        @first_level.position.should == 1
        @second_level.position.should == 2
        @first_level_in_other_game.position.should == 1
      end
    end
  end

  describe "when author entered incorrect data" do
    before :each do
      @author = create_user
      @game = create_game :author => @author
      @params = { }
      Level.new(@params).should_not be_valid
    end

    it "does not create a new level" do
      expect do
        perform_request({ :as_user => @author }, { :level => @params })
      end.not_to change(Level, :count)
    end
  end

  def perform_request(opts={}, params={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    post :create, params: params.merge(:game_id => @game.id)
    response
  end
end
