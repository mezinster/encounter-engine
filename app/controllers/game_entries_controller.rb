# -*- encoding : utf-8 -*-
class GameEntriesController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :find_game, only: :new
  before_action :find_team, only: :new
  before_action :find_entry, except: :new
  before_action :ensure_author, only: [:accept, :reject]
  # Deliberately NOT SecurityFilters#ensure_team_captain -- see the method below
  # for why "a captain" is not a sufficient check in this controller.
  before_action :ensure_captain_of_target_team, except: [:accept, :reject]
  before_action :ensure_game_is_not_withdrawn, only: [:new, :reopen]

  def new
    if @game.can_request?
      @game_entry = GameEntry.create!(status: "new", game: @game, team: @team)
      @game.reserve_place_for_team!
    end
    redirect_to dashboard_path
  end

  def reopen
    if @game.can_request?
      @entry.reopen! unless @entry.status == "accepted"
      @game.reserve_place_for_team!
    end
    redirect_to dashboard_path
  end

  def accept
    @entry.accept! if @entry.status == "new"
    redirect_to dashboard_path
  end

  def reject
    @entry.reject! if @entry.status == "new"
    @game.free_place_of_team!
    redirect_to dashboard_path
  end

  def recall
    @entry.recall! if @entry.status == "new"
    @game.free_place_of_team!
    redirect_to dashboard_path
  end

  def cancel
    @entry.cancel! if @entry.status == "accepted"
    @game.free_place_of_team!
    redirect_to dashboard_path
  end

  private

  # No params[:game_entry] anywhere in this controller -- every action
  # resolves @game/@team/@entry from route id segments (see config/routes.rb),
  # not from a submitted form, so there is no strong-parameters hole to close
  # here.
  def find_game
    @game = Game.find(params[:game_id])
  end

  def find_team
    @team = Team.find(params[:team_id])
  end

  def find_entry
    @entry = GameEntry.find(params[:id])
    @game = Game.find(@entry.game.id) if @entry
  end

  # SecurityFilters#ensure_team_captain asks "is this user *a* captain" and
  # stops there. That is enough for its other two callers, because neither
  # takes a team from the request: InvitationsController#create hardcodes
  # `to_team: current_user.team`, and GamePassingsController#exit_game resolves
  # its passing through `GamePassing.of(@team, @game)`.
  #
  # This controller is the exception -- its target team comes from the URL,
  # either params[:team_id] (#new) or the entry's own team (everything else) --
  # and both are looked up unscoped. Pairing an unscoped lookup with a check
  # that never names the record being acted on is the same shape as the
  # cross-tenant hole fixed in the level/question/answer/option/hint
  # controllers.
  #
  # Reachable before this existed, both ways: any captain could recall, cancel
  # or reopen another team's entry, and could register a DIFFERENT team for a
  # game -- reserve_place_for_team! then consumed one of that game's limited
  # slots on their behalf. spec/requests/game_entry_authorization_spec.rb pins
  # both.
  def ensure_captain_of_target_team
    team = @entry ? @entry.team : @team

    raise Authentication::Unauthorized, t("errors.must_be_captain") unless
      team && team.captain&.id == current_user.id
  end

  # can_request? cannot be used for this: its capacity check discards its own
  # result and the method always returns a truthy array -- a pre-existing bug
  # from the Merb port, out of scope here. This guard stands on its own.
  def ensure_game_is_not_withdrawn
    raise Authentication::Unauthorized, t("errors.game_is_withdrawn") if @game&.withdrawn?
  end
end
