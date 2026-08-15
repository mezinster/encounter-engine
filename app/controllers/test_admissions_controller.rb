# -*- encoding : utf-8 -*-
# Who, besides the author's own team, may play a test run.
#
# Everything except #invite/#join is author-or-superadmin: SecurityFilters#
# ensure_author already returns early for superadmins, which is what satisfies
# the "or superadmin" half of this feature with no second permission concept.
class TestAdmissionsController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :find_game
  before_action :ensure_author,             :except => [ :invite, :join ]
  # A locked author must not be able to bring fresh people into the game an
  # operator locked to investigate -- the same reasoning this filter's own
  # comment records for finish_test, which deletes the evidence.
  before_action :ensure_editing_not_locked, :except => [ :invite, :join ]
  before_action :ensure_game_is_testing

  def create_team
    name = params[:name].to_s.strip
    team = Team.find_by(:name => name)

    if team.nil?
      return redirect_to game_path(@game),
                         :alert => t("test_admissions.team_not_found", :name => name)
    end

    if TestAdmission.exists?(:game_run_id => run.id, :team_id => team.id)
      return redirect_to game_path(@game),
                         :notice => t("test_admissions.already_admitted", :name => team.name)
    end

    TestAdmission.create!(:game_run => run, :team => team)
    record_admin_action("test_admit_team", @game, team.name) if acting_as_operator?(@game)

    redirect_to game_path(@game),
                :notice => t("test_admissions.team_admitted", :name => team.name)
  end

  def create_player
    nickname = params[:nickname].to_s.strip
    user     = User.find_by(:nickname => nickname)

    if user.nil?
      return redirect_to game_path(@game),
                         :alert => t("test_admissions.player_not_found", :name => nickname)
    end

    # The author plays a test run through may_start_passing?'s own exemption.
    # An admission would be a second, redundant grant -- and a disposable team
    # nobody ever uses for teardown to sweep.
    if @game.created_by?(user)
      return redirect_to game_path(@game),
                         :notice => t("test_admissions.author_needs_no_admission")
    end

    if TestAdmission.exists?(:game_run_id => run.id, :user_id => user.id)
      return redirect_to game_path(@game),
                         :notice => t("test_admissions.already_admitted", :name => user.nickname)
    end

    TestAdmission.admit_player!(run, user)
    record_admin_action("test_admit_player", @game, user.nickname) if acting_as_operator?(@game)

    redirect_to game_path(@game),
                :notice => t("test_admissions.player_admitted", :name => user.nickname)
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  def run
    @run ||= @game.current_run
  end

  # Admissions exist only for the duration of a test. Outside one there is
  # nothing to grant and nothing to revoke.
  def ensure_game_is_testing
    raise Authentication::Unauthorized, t("errors.game_is_not_testing") unless @game.is_testing?
  end
end
