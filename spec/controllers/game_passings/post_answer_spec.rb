# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe GamePassingsController, "#post_answer", type: :controller do
  before :each do
    now = Time.now
    Time.stub(:now => now - 1)
    @game = create_game :starts_at => now

    @correct_answer = "enfirstlevel"
    @first_level = create_level :game => @game, :correct_answer => @correct_answer
    @second_level = create_level :game => @game
    @final_level = create_level :game => @game

    @game.reload
    Time.stub(:now => now + 1)

    @team_member = create_user
    @team = create_team :captain => @team_member
    create_game_entry :game => @game, :team => @team
  end

  describe "when a team member enters game passing" do
    context "with correct answer" do
      before :each do
        @response = perform_request :answer => @correct_answer
      end

      it "should assign @answer_was_correct to true" do
        assigns(:answer_was_correct).should be_truthy
      end

      it "should assign @answer to the posted answer" do
        assigns(:answer).should == @correct_answer
      end
    end

    context "with wrong answer" do
      before :each do
        @response = perform_request :answer => 'enblablablabalbla'
      end

      it "should assign @answer_was_correct to false" do
        assigns(:answer_was_correct).should be_falsey
      end

      it "should assign @answer to the posted answer" do
        assigns(:answer).should == 'enblablablabalbla'
      end
    end

    context "with correct but surrounded by spaces answer" do
      before :each do
        @response = perform_request :answer => "   #{@correct_answer}  "
      end

      it "should assign @answer_was_correct to true" do
        assigns(:answer_was_correct).should be_truthy
      end

      it "should assign @answer to the posted answer" do
        assigns(:answer).should == @correct_answer
      end
    end
  end

  def perform_request(opts={})
    session[:user_id] = @team_member.id
    post :post_answer, params: { game_id: @game.id, answer: opts[:answer] }
    response
  end
end
