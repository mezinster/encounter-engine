# -*- encoding : utf-8 -*-
class GamePassingsController < ApplicationController
  include SecurityFilters

  before_action :find_game, except: [:exit_game]
  before_action :find_game_by_id, only: [:exit_game]
  # Authentication first: find_team dereferences current_user, so running it
  # before this filter turned a guest's request into a 500.
  before_action :require_authentication!, except: [:index, :show_results]
  before_action :find_team, except: [:show_results, :index]
  before_action :find_or_create_game_passing, except: [:show_results, :index]
  before_action :ensure_game_is_started
  before_action :ensure_team_captain, only: [:exit_game]
  before_action :ensure_game_not_finished_by_author, except: [:index, :show_results]
  before_action :ensure_team_not_exited, except: [:index, :show_results]
  before_action :ensure_team_member, except: [:index, :show_results]
  before_action :ensure_not_author_of_the_game, except: [:index, :show_results]
  before_action :ensure_author, only: [:index]

  def show_current_level
    @level = @game_passing.current_level
    # TODO(Task 9): the Merb original rendered this with a dedicated
    # "in_game" layout (app/views/layout/in_game.html.erb). App views/layouts
    # are out of this task's scope and that file hasn't been moved to Rails'
    # app/views/layouts/ yet, so an explicit `layout: "in_game"` here would
    # raise ActionView::MissingTemplate on every request, not just in tests.
    # Falls back to the controller's default layout until Task 9 ports it;
    # restore `layout: "in_game"` at that point.
  end

  def index
    @game_passings = GamePassing.of_game(@game)
  end

  def get_current_level_tip
    next_hint = @game_passing.upcoming_hints.first

    render json: { hint_num: @game_passing.hints_to_show.length,
                    hint_text: @game_passing.hints_to_show.last.text,
                    next_available_in: next_hint&.available_in(@game_passing.current_level_entered_at) }
  end

  def post_answer
    if @game_passing.finished?
      render :show_results
      return
    end

    # params[:answer] is a bare string. Guard the type: a crafted request
    # sending answer[value]=... made the Merb app raise on String#strip.
    # Stripped up front (matching the Merb original) rather than relying on
    # GamePassing#check_answer!'s internal strip!, which mutates in place --
    # save_log below must see the trimmed value, same as the original.
    raw_answer = params[:answer]
    @answer = raw_answer.is_a?(String) ? raw_answer.strip : ""
    save_log
    @answer_was_correct = @game_passing.check_answer!(@answer)

    if @game_passing.finished?
      render :show_results
    else
      # See the TODO in #show_current_level about the "in_game" layout.
      render :show_current_level
    end
  end

  def show_results
  end

  def exit_game
    @game_passing.exit!
    render :show_results
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  def find_game_by_id
    @game = Game.find(params[:id])
  end

  def find_team
    @team = current_user.team
  end

  # TODO: must be a critical section, double creation is possible!
  def find_or_create_game_passing
    @game_passing = GamePassing.of(@team, @game) ||
                    GamePassing.create!(team: @team, game: @game,
                                         current_level: @game.levels.first)
  end

  def save_log
    return unless @game_passing.current_level&.id

    level = Level.find(@game_passing.current_level.id)
    Log.create!(game_id: @game.id, level: level.name, team: @team.name,
                time: Time.now, answer: @answer)
  end

  def ensure_game_is_started
    return if @game.is_testing?
    raise Authentication::Unauthorized, t("game.not_started") unless @game.started?
  end

  def ensure_not_author_of_the_game
    return if @game.is_testing?
    raise Authentication::Unauthorized, t("errors.cannot_play_own_game") if @game.created_by?(current_user)
  end

  def ensure_game_not_finished_by_author
    raise Authentication::Unauthorized, t("errors.game_finished_by_author") if @game.author_finished?
  end

  def ensure_team_not_exited
    raise Authentication::Unauthorized, t("errors.team_exited") if @game_passing.exited?
  end
end
