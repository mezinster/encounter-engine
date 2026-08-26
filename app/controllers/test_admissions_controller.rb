# -*- encoding : utf-8 -*-
# Who, besides the author's own team, may play a test run.
#
# Everything except #invite/#join is author-or-superadmin-or-gated-operator:
# SecurityFilters#ensure_author already returns early for superadmins, and
# for an operator on a gated game, which is what satisfies that half of this
# feature with no second permission concept.
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
  # The link pair's only gate, in place of ensure_author: the 24 random bytes
  # ARE the authorization.
  before_action :ensure_token_matches, :only => [ :invite, :join ]

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

    delivered = notify(recipients_for(team)) do |recipient|
      NotificationMailer.test_admission_notification(recipient, @game, team)
    end

    redirect_with_delivery_result(delivered, "team_admitted", team.name)
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

    # nil team: the admission DOES have one in the database, but it is the
    # disposable team admit_player! just created -- no members, no captain, and
    # no name the recipient would recognise. See NotificationMailer.
    delivered = notify([ user ]) do |recipient|
      NotificationMailer.test_admission_notification(recipient, @game, nil)
    end

    redirect_with_delivery_result(delivered, "player_admitted", user.nickname)
  end

  def revoke
    # Scoped to THIS run, not TestAdmission.find(params[:id]). An unscoped
    # lookup paired with an authorization check that never names the record is
    # the shape of the cross-tenant hole fixed in the level, question, answer,
    # option and hint controllers: the author of game A would otherwise be able
    # to revoke an admission belonging to game B.
    admission = TestAdmission.find_by(:id => params[:id], :game_run_id => run.id)

    raise ActiveRecord::RecordNotFound if admission.nil?

    # Read BEFORE the revoke: afterwards the row is gone and the disposable
    # team with it, so neither the notice nor the audit entry could say who.
    label = admission.solo? ? admission.user&.nickname : admission.team.name

    # Read before the revoke, mirroring the label above -- but be honest about
    # what that is worth, because the obvious reason is wrong. revoke! destroys
    # the team only for a SOLO admission (`doomed = solo? ? team : nil`), and
    # the solo branch here reads admission.user, whose row it never touches. A
    # team admission's team survives outright. Mutation-tested: moving both
    # reads below revoke! leaves the suite green.
    #
    # Kept above it anyway, for the same reason TestAdmission.held_by keeps its
    # non-load-bearing team guard -- it costs nothing and states the intent
    # ("these are the people this admission covered") at the point where that
    # is still unambiguously true. It is not load-bearing today, and a future
    # reader who moves it will not break anything.
    team_for_letter = admission.solo? ? nil : admission.team
    recipients      = admission.solo? ? [ admission.user ].compact
                                      : recipients_for(admission.team)

    admission.revoke!
    record_admin_action("test_revoke_admission", @game, label) if acting_as_operator?(@game)

    delivered = notify(recipients) do |recipient|
      NotificationMailer.test_admission_revoked(recipient, @game, team_for_letter)
    end

    redirect_with_delivery_result(delivered, "revoked", label)
  end

  # GET. Renders a confirmation page and admits nobody -- see the routes
  # comment for why a state-changing GET is wrong for a link meant to be
  # pasted into a chat.
  def invite
    redirect_to show_current_level_path(:game_id => @game.id) if already_playing?
  end

  # POST. The actual grant.
  def join
    return redirect_to show_current_level_path(:game_id => @game.id) if already_playing?

    TestAdmission.admit_player!(run, current_user)

    redirect_to show_current_level_path(:game_id => @game.id),
                :notice => t("test_admissions.joined", :game => @game.name)
  end

  # Revokes the outstanding link by replacing it. update_column for the same
  # reason start_test uses it -- a game mid-test fails its own validations.
  def reset_token
    run.update_column(:test_token, SecureRandom.urlsafe_base64(24))
    record_admin_action("test_reset_token", @game) if acting_as_operator?(@game)

    redirect_to game_path(@game), :notice => t("test_admissions.token_reset")
  end

  private

  # "The captain, plus all members." Team#adopt_captain already forces the
  # captain into members, so the union is a no-op on every team that exists
  # today and .uniq is the part doing real work -- without it a captain would
  # get two identical letters. The union is written out anyway so that a team
  # whose captain somehow sits outside members still reaches them.
  def recipients_for(team)
    (team.members.to_a + [ team.captain ]).compact.uniq
  end

  # One MailDelivery.attempt per recipient, accumulated with `&` -- NOT `&&`.
  # It must not short-circuit: the grant is already written, one unreachable
  # address must not deny the rest of the team their letter, and the caller
  # wants a single summary flash rather than one per recipient. Same idiom and
  # same reasoning as InvitationsController#reject_rest_of_invitations.
  def notify(recipients)
    recipients.reduce(true) do |all_delivered, recipient|
      all_delivered & MailDelivery.attempt { yield(recipient).deliver_now }
    end
  end

  # alert:, not notice:, on the unnotified branch -- components.css gives
  # .flash--alert a danger border, and the four invitation sites already warn
  # in red for this same class of failure. The operation itself succeeded
  # either way; what failed is only the telling.
  def redirect_with_delivery_result(delivered, key, name)
    if delivered
      redirect_to game_path(@game), :notice => t("test_admissions.#{key}", :name => name)
    else
      redirect_to game_path(@game), :alert => t("test_admissions.#{key}_unnotified", :name => name)
    end
  end

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

  # The author needs no admission -- may_start_passing? exempts them -- and
  # anyone already admitted needs no second one. Both cases go straight to
  # play rather than erroring: following your own invite link twice is not a
  # mistake worth a red message.
  def already_playing?
    @game.created_by?(current_user) ||
      TestAdmission.exists?(:game_run_id => run.id, :user_id => current_user.id)
  end

  # secure_compare rather than ==. The 24 random bytes are what really protect
  # this, not the comparison, but a timing-safe check costs nothing and keeps
  # the habit intact for the next credential someone adds.
  #
  # The stored.present? guard is load-bearing on its own: finish_test nils the
  # column, and secure_compare(nil, "") would otherwise decide a finished test
  # is joinable by anyone who sends an empty token.
  def ensure_token_matches
    stored = run.test_token
    given  = params[:token].to_s

    valid = stored.present? &&
            ActiveSupport::SecurityUtils.secure_compare(stored, given)

    raise Authentication::Unauthorized, t("errors.bad_test_token") unless valid
  end
end
