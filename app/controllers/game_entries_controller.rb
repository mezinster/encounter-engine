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

  # GameEntry.of(@team, @game) is deliberately not used for this check: it
  # prefers an "accepted" row over any other, which is exactly the wrong bias
  # here -- an existing rejected/recalled/canceled row must still block a
  # fresh #new (the team is expected to use "reopen" on it instead, see
  # shared/_game_entry_controls.html.erb), not be shadowed by a search for an
  # accepted one that doesn't exist yet.
  def new
    if @game.can_request? && !GameEntry.of_team(@team).of_game(@game).exists?
      @game_entry = GameEntry.create!(status: "new", game: @game, team: @team)
      @game.reserve_place_for_team!
    end
    redirect_to dashboard_path
  end

  # reserve_place_for_team! must only fire when reopen! actually ran. It used
  # to sit unconditionally inside the `if @game.can_request?` block, so
  # reopening an entry that was already "accepted" (reopen! a no-op) still
  # reserved a second place for a team that already held one.
  def reopen
    if @game.can_request? && @entry.status != "accepted"
      @entry.reopen!
      @game.reserve_place_for_team!
    end
    redirect_to dashboard_path
  end

  def accept
    @entry.accept! if @entry.status == "new"
    redirect_to dashboard_path
  end

  # free_place_of_team! must only fire when reject! actually ran, or a second
  # reject (already-rejected entry, e.g. a double-clicked button) frees a
  # place that isn't this entry's to free -- see recall's comment below for
  # the full failure mode.
  def reject
    if @entry.status == "new"
      @entry.reject!
      @game.free_place_of_team!
    end
    redirect_to dashboard_path
  end

  # Same shape as reject/cancel: free_place_of_team! rides along with recall!
  # instead of firing unconditionally. Game#free_place_of_team! floors at
  # zero, so a double recall of a team's ONLY active entry is harmless either
  # way -- the drift only shows up (and did, in production use, per a
  # captain double-clicking "Отозвать") when the game has other active
  # entries: the counter decrements past what's actually free, letting one
  # extra team past max_team_number.
  def recall
    if @entry.status == "new"
      @entry.recall!
      @game.free_place_of_team!
    end
    redirect_to dashboard_path
  end

  def cancel
    if @entry.status == "accepted"
      @entry.cancel!
      @game.free_place_of_team!
    end
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

  # can_request? cannot be used for this: it answers a capacity question, not
  # a withdrawal one. This guard stands on its own.
  def ensure_game_is_not_withdrawn
    raise Authentication::Unauthorized, t("errors.game_is_withdrawn") if @game&.withdrawn?
  end
end
