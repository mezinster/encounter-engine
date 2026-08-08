class DeleteOrphanGamePassings < ActiveRecord::Migration[8.0]
  # GamePassing rows with team_id NULL are legacy. find_or_create_game_passing
  # still runs ahead of ensure_team_member in GamePassingsController's filter
  # chain -- that ordering never changed and is not what guards this. The
  # code path that could write one was closed by the `return false if
  # @team.nil?` guard in may_start_passing?, added during the 2026-08-07
  # gameplay access-control remediation, which refuses before
  # GamePassing.create! is ever reached (see find_or_create_game_passing's
  # and may_start_passing?'s comments in
  # app/controllers/game_passings_controller.rb). No migration since then
  # re-opens it, and no UI can delete an orphan once it exists.
  #
  # These rows are not merely dormant: game_passings/index.html.erb (the
  # author's stats page) dereferences game_passing.team.name unconditionally,
  # so any orphan permanently 500s that page for its game. Worse,
  # GamesController#end_game calls `.each(&:end!)` over every passing for the
  # game, orphans included, which stamps status = "ended" on them too -- and
  # show_results.html.erb, the PUBLIC, unauthenticated results page, makes the
  # same team.name dereference. One orphan row breaks a page anyone on the
  # internet can hit.
  #
  # Deleting outright is safe here specifically because the data cannot be
  # recreated by design: no running code can produce a new team_id NULL row,
  # so there is nothing "in progress" to lose and no later feature that could
  # need to read one back. If this proves wrong, the rollback path is
  # docs/runbooks/restore.md's WAL-based point-in-time restore -- not an
  # in-app undo, which is why #down below refuses rather than pretending to
  # reverse this.
  def up
    deleted = GamePassing.where(:team_id => nil).delete_all
    say "deleted #{deleted} orphan game_passings row(s) with team_id NULL"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "orphan game_passings rows were deleted outright and cannot be reconstructed; " \
      "restore from a WAL backup per docs/runbooks/restore.md if this needs undoing"
  end
end
