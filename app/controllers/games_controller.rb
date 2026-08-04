# -*- encoding : utf-8 -*-
class GamesController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!, except: [:index, :show]
  before_action :find_game, only: [:show, :edit, :update, :delete, :end_game, :start_test, :finish_test]
  before_action :ensure_author, only: [:edit, :update]
  before_action :ensure_game_was_not_started, only: [:edit, :update]

  def index
    @games = if params[:user_id].present?
               User.find(params[:user_id]).created_games
             else
               Game.non_drafts
             end
  end

  def new
    @game = Game.new
  end

  def create
    @game = Game.new(game_params.merge(author: current_user))

    if @game.save
      redirect_to @game
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @game_entries = GameEntry.of_game(@game).with_status("new")
    @teams = GameEntry.of_game(@game).with_status("accepted").map(&:team)
  end

  def edit
  end

  def update
    if @game.update(game_params)
      redirect_to @game
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def delete
    @game.destroy
    redirect_to dashboard_path
  end

  def end_game
    @game.finish_game!
    GamePassing.of_game(@game).each(&:end!)
    redirect_to dashboard_path
  end

  def start_test
    @game.is_draft = false
    @game.is_testing = true
    @game.test_date = @game.starts_at
    @game.starts_at = Time.now + 0.1.second
    @game.registration_deadline = nil
    @game.save!

    redirect_to @game
  end

  def finish_test
    @game.is_draft = true
    @game.is_testing = false
    @game.starts_at = @game.test_date
    @game.test_date = Time.now
    @game.save!

    GamePassing.of_game(@game).delete_all
    Log.of_game(@game).delete_all

    redirect_to @game
  end

  private

  # Merb passed params[:game] straight to update_attributes with no
  # top-level key required. fetch (rather than require) keeps that
  # tolerance -- a request with no :game key at all builds a blank/invalid
  # Game instead of raising ActionController::ParameterMissing -- while
  # permit still closes the mass-assignment hole. Field list matches the
  # actual form fields in app/views/games/new.html.erb and edit.html.erb;
  # is_testing is never submitted by either form (it's flipped only via
  # #start_test/#finish_test) so it is intentionally not permitted here.
  def game_params
    params.fetch(:game, ActionController::Parameters.new)
          .permit(:name, :description, :starts_at, :registration_deadline,
                   :max_team_number, :is_draft)
  end

  def find_game
    @game = Game.find(params[:id])
  end
end
