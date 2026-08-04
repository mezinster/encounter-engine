# -*- encoding : utf-8 -*-
class GamesController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!, except: [:index, :show]
  before_action :find_game, only: [:show, :edit, :update, :delete, :end_game, :start_test, :finish_test]
  before_action :find_team, only: [:show]
  before_action :ensure_author_if_game_is_draft, only: [:show]
  before_action :ensure_author_if_no_start_time, only: [:show]
  before_action :ensure_author, only: [:edit, :update, :delete, :end_game, :start_test, :finish_test]
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

  # No view reads @team today (Task 9 hasn't ported app/views/games/show yet),
  # but the Merb original set it unconditionally on #show and dropping it
  # silently would change what that port can rely on.
  def find_team
    @team = current_user&.team
  end

  def game_is_draft?
    @game.draft?
  end

  def no_start_time?
    @game.starts_at.nil?
  end

  # A draft or not-yet-scheduled game is only visible to its author -- a
  # guest or any other user gets Unauthorized (via SecurityFilters#ensure_author,
  # which itself distinguishes "not logged in" from "logged in but not the
  # author" -- both land here as a 401, matching the Merb original). Without
  # these two guards, an unpublished game's name/description/level count
  # leak from the moment its author saves the draft, before it's meant to be
  # public.
  def ensure_author_if_game_is_draft
    ensure_author if game_is_draft?
  end

  def ensure_author_if_no_start_time
    ensure_author if no_start_time?
  end
end
