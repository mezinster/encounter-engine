# app/controllers/concerns/admin_audit.rb
#
# Recording is an EXPLICIT call at each site, never an around_action.
#
# A filter that decides what is auditable by inspecting the request is exactly
# the construct that silently stops covering a newly added action. This project
# has already been bitten by that shape: splitting the editing lock out of
# ensure_author quietly narrowed it from six actions to three and left
# finish_test able to erase player history, and no per-task review saw it. An
# explicit call shows up in the diff of any new action; a clever filter does not.
#
# The cost is that someone adding an action can forget the call.
# spec/requests/admin_audit_spec.rb enumerates the audited actions and is the
# guard -- it must be updated deliberately when the set changes, which is the point.
module AdminAudit
  extend ActiveSupport::Concern

  private

  # Call AFTER the change has landed, never before. A refused deletion that
  # left an entry would make the log unreadable: an investigator could not tell
  # which entries were real.
  #
  # Deliberately not wrapped in a transaction with the action. If this write
  # fails the action still stands -- an operator unable to withdraw a game
  # because the audit table is unavailable is a worse outcome than a missing row.
  def record_admin_action(action, target = nil, details = nil)
    AdminAction.create!(
      :actor_id     => current_user&.id,
      # Snapshotted for the same reason as target_label below: an actor row
      # can go away, and an entry naming a number nobody can resolve is the
      # worst thing an audit trail can hold.
      :actor_label  => current_user&.nickname,
      :action       => action.to_s,
      :target_type  => target&.class&.name,
      :target_id    => target&.id,
      :target_label => AdminAction.label_for(target),
      :details      => details
    )
  end

  # Audited only when an operator acts on someone else's game. An author
  # acting on their own game is ordinary use, not an administrative act, and
  # recording it would bury the administrative entries under routine ones.
  #
  # Compares author_id directly rather than calling User#author_of?, which is
  # `game.author.id == self.id` and raises on a game whose author is missing.
  #
  # Lives here rather than on GamesController because InterventionsController
  # needs the same test; it takes the game explicitly so neither controller
  # depends on a particular instance variable being set.
  #
  # NAMING, since a role called `operator` now exists: this predicate is about
  # a CAPACITY (acting on a game you did not author), not about holding
  # User#operator?. A superadmin who holds no role still acts as an operator
  # here. Sub-project B widens the superadmin? test below to
  # may_operate_commercial?, or an operator's acts on commercial games they did
  # not author go unrecorded -- which is the whole population the role creates.
  def acting_as_operator?(game)
    logged_in? && current_user.superadmin? && game.author_id != current_user.id
  end
end
