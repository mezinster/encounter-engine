# -*- encoding : utf-8 -*-
class GamePassingsController < ApplicationController
  include SecurityFilters

  before_action :find_game
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

  # TICKET #83 ("Игрок удачно обновляется при завершении игры"): a team that
  # has finished has no current_level, so rendering show_current_level for one
  # raised NoMethodError on nil at
  # app/views/game_passings/show_current_level.html.erb:5 -- i.e. refreshing the
  # page at game end 500'd. #post_answer already had exactly this guard (see
  # below); GET simply never got it, in the Merb original as much as here. The
  # scenario that is supposed to cover this,
  # features/tickets/ticket-83(5).feature:29, could not see the bug because the
  # "я обновляю страницу" step was an empty no-op -- it is implemented now
  # (features/game-passing/steps/game-passing_steps.rb), so that scenario is a
  # real regression test for the first time.
  #
  # Same predicate, same template and the same default-layout choice as
  # #post_answer, so a team that has NOT finished is unaffected.
  def show_current_level
    if @game_passing.finished?
      render :show_results
      return
    end

    @level = @game_passing.current_level
    render layout: "in_game"
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
      render :show_current_level, layout: "in_game"
    end
  end

  def show_results
  end

  def exit_game
    @game_passing.exit!
    render :show_results
  end

  private

  # PORT DEFECT, now fixed (found by
  # features/game-passing/throw_in_the_towel.feature): there used to be a second
  # finder, #find_game_by_id, used only by #exit_game and reading params[:id].
  # Merb reached #exit_game through the catch-all /:controller/:action/:id
  # route, so the game did arrive as params[:id] there -- but the Rails route
  # restored for it names the segment :game_id
  # ("/game_passings/exit_game/:game_id", config/routes.rb), as do the link that
  # drives it (app/views/game_passings/show_current_level.html.erb) and
  # spec/routing_spec.rb. Every "Сойти с дистанции" click therefore raised
  # RecordNotFound before the action ever ran. Once corrected the two finders
  # were byte-identical, so #exit_game just uses this one.
  def find_game
    @game = Game.find(params[:game_id])
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
