# -*- encoding : utf-8 -*-
class TeamsController < ApplicationController
  before_action :require_authentication!, :except => [ :show ]
  before_action :ensure_not_member_of_any_team, only: [:new, :create]

  # Discovery for join requests. `resources :teams` already routed index and
  # it 404'd via ActionNotFound, so this fills an existing slot rather than
  # adding a route.
  #
  # No frozen scenario visits a teams list -- create-team.feature only visits
  # /teams/new -- so this page carries no acceptance assertions.
  def index
    # captain and members are both read per row, so both are preloaded:
    # without them this issues two extra queries per team. Pinned by the
    # slope guard in spec/requests/teams_index_spec.rb.
    @teams = Team.includes(:captain, :members).order(:name)
    # One query for the viewer's pending applications rather than one per
    # row, for the same reason.
    @pending_team_ids = TeamJoinRequest.pending.of_user(current_user).pluck(:team_id)

    # Four grouped queries for the whole page, whatever the number of teams.
    # Never a lookup per row: teams_index_spec.rb pins a flat count, and this
    # programme has broken that class of guard three times already.
    @earned    = PointTransaction.where("amount > 0").group(:team_id).sum(:amount)
    @deducted  = PointTransaction.where("amount < 0").group(:team_id).sum(:amount)
    #
    # not_testing on both: a rehearsal writes no ledger row (GamePassing
    # #award_points_for returns early for a testing run), so counting its
    # passings here made a team that has never played anything real read
    # "1 game started, 1 game finished, 0 points" -- and gave the disposable
    # "<nickname> (test #N)" teams chart rows of their own for the duration of
    # a test. Same exclusion as the awarding side, so the four columns of a
    # row now describe the same population.
    #
    # `completed`, not finished_at: an exited run stamps finished_at as well
    # as its status, and walking off the course is not completing it (P4). The
    # team's own page reads the same predicate through
    # GamePassing#completed?.
    @started   = GamePassing.not_testing.group(:team_id).count
    @finished  = GamePassing.not_testing.completed.group(:team_id).count

    # Sorted in Ruby, from figures already loaded, rather than by adding a
    # join and an ORDER BY to the relation above: the page renders tens of
    # teams, and a join here would fight the preloads.
    #
    # Name is the tie-break, so teams on equal points -- which at launch is
    # every team, all on zero -- keep the alphabetical order the relation
    # already applied instead of coming back in whatever order the sort felt
    # like.
    @teams = @teams.to_a.sort_by { |t| [ -balance_of(t), t.name.to_s ] }
  end

  # Public: the chart links here, and P9 makes the whole ledger readable.
  # TeamRoomController is the team's own room, behind ensure_team_member, and
  # is a different thing.
  def show
    @team = Team.find(params[:id])

    # Preloaded because both tables below name the game: without this the
    # ledger issues one query per row. Only :game -- the level is preloaded
    # nowhere and named nowhere; a `:level` half sat here for a while,
    # spending a query per page load on a column the view has never rendered.
    @transactions = @team.point_transactions.includes(:game).order(:created_at => :desc)

    # One row per attempt, with what that attempt was worth -- a grouped sum,
    # not a per-attempt lookup.
    @passings = @team.game_passings.includes(:game).order(:created_at => :desc)
    @per_attempt = @team.point_transactions.group(:game_passing_id).sum(:amount)

    # P9 made the LEDGER public, not the game catalogue -- see
    # #nameable_game_ids.
    @nameable_game_ids =
      nameable_game_ids(@passings.map(&:game) + @transactions.map(&:game))
  end

  def new
    @team = Team.new
  end

  def create
    @team = Team.new(team_params)
    @team.captain = current_user

    if @team.save
      redirect_to dashboard_path
    else
      render :new, status: :unprocessable_entity
    end
  end

  # A captain hands the role to a teammate (D2 of the design). The superadmin
  # equivalent lives in Admin::TeamsController#set_captain; both go through
  # Team#set_captain! and nothing else writes captain_id.
  def hand_over
    team = Team.find(params[:id])

    # The STRICT guard: the team comes from the URL and the actor must be
    # THIS team's captain. Deliberately not SecurityFilters
    # #ensure_team_captain, which only asks "is this user a captain" and
    # derives the team from current_user -- it would admit the captain of any
    # other team to this action. Same reasoning as
    # GameEntriesController#ensure_captain_of_target_team, which exists
    # because that controller also takes its team from the URL.
    raise Authentication::Unauthorized, t("errors.must_be_captain") unless
      team.captain && team.captain.id == current_user.id

    # D1: member-initiated changes wait for the race to end. The superadmin
    # path is deliberately unguarded here -- see the comment on
    # Team#in_live_race?.
    if team.in_live_race?
      redirect_to team_room_path, :alert => t("teams.cannot_hand_over_mid_race") and return
    end

    # Scoped through team.members, so a crafted id from another team resolves
    # to nil and is refused rather than reaching set_captain! and raising.
    successor = team.members.find_by(:id => params[:member_id])

    if successor.nil? || successor.id == current_user.id
      redirect_to team_room_path, :alert => t("teams.hand_over_needs_another_member") and return
    end

    team.set_captain!(successor)
    redirect_to team_room_path,
                :notice => t("teams.handed_over", :nickname => successor.nickname)
  end

  # Leaving exists so ensure_not_member_of_any_team stops being a trap: until
  # now nothing in the app set users.team_id back to nil, so a user belonged
  # to one team permanently -- and if its captain stopped logging in, every
  # member was stuck there with it.
  #
  # The team comes from current_user, never from a parameter: there is no id
  # here to forge.
  def leave
    team = current_user.team

    if team.nil?
      redirect_to dashboard_path, :alert => t("teams.not_in_a_team") and return
    end

    # D1: member-initiated changes wait for the race to end.
    if team.in_live_race?
      redirect_to team_room_path, :alert => t("teams.cannot_leave_mid_race") and return
    end

    # A captain with teammates must hand over first, or the team is left
    # bricked -- no invitations, no registration, no way to quit a race. The
    # handover control sits in the same fieldset of the team room, so this
    # refusal is a signpost rather than a dead end.
    solo = team.members.count == 1

    if current_user.captain? && !solo
      redirect_to team_room_path, :alert => t("teams.hand_over_before_leaving") and return
    end

    Team.transaction do
      # D5: a solo captain takes the role with them. Clearing captain_id is
      # not optional -- a dangling one would point team.captain at a
      # non-member while User#captain?, which reads through user.team, says
      # false. That divergence is what makes the weak
      # SecurityFilters#ensure_team_captain guard exploitable.
      #
      # This is the first thing in the app that can produce captain_id IS
      # NULL, which is what turns NotificationMailer's captainless guard from
      # precautionary into load-bearing.
            team.update!(:captain => nil) if current_user.captain?
      current_user.update!(:team => nil)
    end

    redirect_to dashboard_path, :notice => t("teams.left_notice", :team => team.name)
  end

  private

  # Which of these games this viewer may be told the NAME of.
  #
  # #show is public and unauthenticated by design, and the decision that made
  # it so (P9) was about the ledger -- how a team placed and why. It was not a
  # decision to publish the game catalogue, which every other surface in this
  # application gates: `Game.visible` scopes the games listing, and
  # ensure_author_if_game_draft / _is_withdrawn / _is_testing gate games#show.
  # Without this, an author who admitted a team to test an unreleased game put
  # its title on a public URL, and a withdrawn game kept its title on every
  # participant's page for ever. See the whole-branch review, F1.
  #
  # A game the viewer may not be told about is rendered with a fixed
  # placeholder and its row STAYS -- see #game_title_for_viewer.
  #
  # The entitlement rule is copied from those filters rather than invented:
  # Game.visible for everyone, plus the game's own author, plus a superadmin,
  # plus an operator on a GATED game. That last clause is deliberately
  # game-conditional, exactly as SecurityFilters#ensure_author is: an
  # operator's authority runs to commercial games, and an unscoped
  # `current_user.operator?` here would be wider than anything else in the app
  # allows.
  #
  # ONE query for the whole page, whatever the number of rows -- the flat
  # count guard in spec/requests/team_history_spec.rb pins that, and the
  # author/superadmin/operator tests below read author_id and access_mode off
  # games that are already loaded.
  def nameable_game_ids(games)
    games = games.compact.uniq
    return Set.new if games.empty?

    ids = Game.visible.where(:id => games.map(&:id)).pluck(:id).to_set
    return ids unless logged_in?

    games.each do |game|
      ids << game.id if current_user.superadmin? ||
                        current_user.author_of?(game) ||
                        (current_user.operator? && game.pass_required?)
    end

    ids
  end

  # A neutral, fixed label -- never the title, and never interpolating it.
  # The row is kept rather than dropped on purpose: omitting it would make the
  # public balance stop equalling the sum of the public rows, which reads as a
  # bug in the chart and defeats the point of publishing an itemised ledger.
  # What leaks is only "these points were earned in a game you cannot see".
  def game_title_for_viewer(game)
    return t("teams.show.hidden_game") if game.nil? || !@nameable_game_ids.include?(game.id)

    game.name
  end
  helper_method :game_title_for_viewer

  # Earned is positive, deducted is negative, so the balance is their sum.
  def balance_of(team)
    @earned.fetch(team.id, 0) + @deducted.fetch(team.id, 0)
  end
  helper_method :balance_of

  def team_params
    params.fetch(:team, ActionController::Parameters.new).permit(:name)
  end

  def ensure_not_member_of_any_team
    raise Authentication::Unauthorized, t("game.already_in_team") if current_user.member_of_any_team?
  end
end
