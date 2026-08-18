# Read-only, and deliberately split: the list carries identity and email, the
# detail page carries contact details. Nothing is hidden from the operator, but
# reading the whole membership's phone numbers takes deliberate clicks rather
# than one glance -- which is what matters once this role can be granted to a
# helper.
#
# NAMING, since a role called `operator` now exists: "the operator" above is a
# CAPACITY -- whichever superadmin is at the console -- not User#operator?.
# This controller stays superadmin-only (require_superadmin! below); granting
# the operator role does not open it. See AdminAudit#acting_as_operator? for
# the same distinction made where it first mattered.
#
# crypted_password and salt are never passed to a view. A spec asserts their
# absence across every reporting screen: the risk is not that someone adds them
# deliberately but that a future `<%= user.attributes %>` leaks them silently.
class Admin::UsersController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!

  def index
    # :team is preloaded because the list renders one per row. Without it this
    # page issues a SELECT per user -- the exact defect the all-games console
    # shipped with, found only when a reviewer instrumented it.
    @users = User.includes(:team).order(:created_at => :desc)
  end

  def show
    @user = User.includes(:team, :created_games).find(params[:id])
  end

  def grant
    user = User.find(params[:id])
    user.update!(:is_superadmin => true)
    record_admin_action("grant_superadmin", user)
    redirect_to admin_user_path(user), :notice => t("admin.users.granted_notice")
  end

  def revoke
    user = User.find(params[:id])

    # Refused before anything changes, so neither guard leaves an entry for a
    # revocation that did not happen.
    if user.id == current_user.id
      redirect_to admin_user_path(user), :alert => t("admin.users.cannot_revoke_self") and return
    end

    if user.last_superadmin?
      redirect_to admin_user_path(user), :alert => t("admin.users.cannot_revoke_last") and return
    end

    user.update!(:is_superadmin => false)
    record_admin_action("revoke_superadmin", user)
    redirect_to admin_user_path(user), :notice => t("admin.users.revoked_notice")
  end

  # The operator role (sub-project A of the commercial-games programme). It
  # grants nothing yet: its authority clause lands in sub-project B, where
  # Game#commercial? will exist to scope it.
  #
  # No self guard and no last-holder guard, unlike #revoke above. Both of that
  # method's guards exist so the instance can never end up with nobody able to
  # administer it; a superadmin can always grant this role back, so neither
  # applies. See docs/superpowers/specs/2026-08-18-operator-role-design.md, D4.
  #
  # record_admin_action is called AFTER the change lands, matching the rule in
  # AdminAudit: a refused action must leave no entry.
  def grant_operator
    user = User.find(params[:id])
    user.update!(:is_operator => true)
    record_admin_action("grant_operator", user)
    redirect_to admin_user_path(user), :notice => t("admin.users.operator_granted_notice")
  end

  def revoke_operator
    user = User.find(params[:id])
    user.update!(:is_operator => false)
    record_admin_action("revoke_operator", user)
    redirect_to admin_user_path(user), :notice => t("admin.users.operator_revoked_notice")
  end

  # Housekeeping -- spam and test accounts. Every refusal exists because the
  # alternative damages something the deleted user does not own. See
  # docs/superpowers/specs/2026-08-08-team-membership-programme-design.md, S5.
  #
  # Refused before anything changes, matching #revoke, so no audit entry is
  # written for a deletion that did not happen.
  def destroy
    user = User.find(params[:id])

    if user.id == current_user.id
      redirect_to admin_user_path(user), :alert => t("admin.users.cannot_delete_self") and return
    end

    # Their team would be left captainless WITH members -- the bricked state
    # this whole programme exists to remove. Reassign the captaincy first.
    if user.captain?
      redirect_to admin_user_path(user),
                  :alert => t("admin.users.cannot_delete_captain") and return
    end

    # last_superadmin_keeps_the_role guards REVOKING the role; destroy walks
    # straight past it. Unreachable through this controller today -- see the
    # note in spec/requests/admin_user_deletion_spec.rb -- because
    # require_superadmin! plus the self guard above already make it
    # impossible to empty the role. Kept because it costs one comparison and
    # is the only thing between a future removal of the self guard and an
    # instance nobody can administer.
    if user.last_superadmin?
      redirect_to admin_user_path(user),
                  :alert => t("admin.users.cannot_delete_last_superadmin") and return
    end

    # Games are content other people played. Orphaning them also 500s
    # games/show.html.erb, which dereferences @game.author.nickname
    # unguarded. Anonymisation exists for exactly this user.
    if user.created_games.any?
      redirect_to admin_user_path(user),
                  :alert => t("admin.users.cannot_delete_author") and return
    end

    nickname = user.nickname
    user.destroy

    # Recorded with the destroyed record, not nil: it is frozen but still
    # readable, so target_label snapshots the nickname while target_id
    # deliberately keeps the id that now points at nothing. That pairing is
    # the whole reason target_label exists -- "User #47" alone would record
    # the loss of the very thing that explains it.
    record_admin_action("delete_user", user)
    redirect_to admin_users_path,
                :notice => t("admin.users.deleted_notice", :nickname => nickname)
  end

  # The other half of D4: identity goes, the row stays. This is how a game
  # author is removed at all -- #destroy refuses one, because orphaning games
  # 500s games/show.html.erb, while here the row survives and the games keep a
  # valid author who simply has no name any more.
  #
  # Deliberately NOT guarded on created_games for that exact reason.
  def anonymise
    user = User.find(params[:id])

    if user.id == current_user.id
      redirect_to admin_user_path(user),
                  :alert => t("admin.users.cannot_anonymise_self") and return
    end

    # Their team would be left with a captain who has no name and cannot log
    # in -- bricked in all but the column. Reassign first.
    if user.captain?
      redirect_to admin_user_path(user),
                  :alert => t("admin.users.cannot_anonymise_captain") and return
    end

    # Placeholders are keyed on the id because both columns are validated
    # unique: two anonymised accounts must not collide.
    user.update!(
      :nickname      => "удалённый-#{user.id}",
      :email         => "deleted-#{user.id}@example.invalid",
      :phone_number  => nil,
      :instagram     => nil,
      :telegram_id   => nil,
      :date_of_birth => nil,
      :on_telegram   => false,
      :on_whatsapp   => false,
      :on_viber      => false,
      :on_signal     => false,
      :on_max        => false,
      # The person is gone, so they neither play nor administer. Detaching
      # also stops a nameless ghost sitting in someone's team roster.
      :team          => nil,
      :is_superadmin => false,
      :is_operator   => false
    )

    record_admin_action("anonymise_user", user)
    redirect_to admin_user_path(user), :notice => t("admin.users.anonymised_notice")
  end

  # Consent-free, so the refusals matter more than the move. See
  # docs/superpowers/specs/2026-08-08-team-membership-programme-design.md, S2.
  # Every guard refuses before anything changes, matching #revoke above, so no
  # audit entry is ever written for a move that did not happen.
  def move
    user = User.find(params[:id])
    destination = Team.find_by(:id => params[:team_id])
    source = user.team

    # Moving a captain would leave their team captainless -- the bricked state
    # this programme exists to remove -- and would put users.team_id and
    # teams.captain_id in disagreement, which is the divergence that makes the
    # weak SecurityFilters#ensure_team_captain guard exploitable. The message
    # names the remedy, or an operator meets a refusal with no hint at the fix.
    if user.captain?
      redirect_to admin_user_path(user), :alert => t("admin.users.cannot_move_captain") and return
    end

    if destination.nil? || destination == source
      redirect_to admin_user_path(user), :alert => t("admin.users.move_needs_another_team") and return
    end

    # D1: consent-free changes wait for the race to end. Both ends matter --
    # joining a run already under way hands the newcomer levels their
    # teammates solved, and leaving one changes a racing team's composition
    # without its captain knowing.
    if destination.in_live_race? || source&.in_live_race?
      redirect_to admin_user_path(user), :alert => t("admin.users.cannot_move_mid_race") and return
    end

    user.update!(:team => destination)
    record_admin_action("move_user", user, "#{source&.name} -> #{destination.name}")
    redirect_to admin_user_path(user),
                :notice => t("admin.users.moved_notice", :team => destination.name)
  end
end
