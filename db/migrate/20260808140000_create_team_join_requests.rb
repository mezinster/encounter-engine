class CreateTeamJoinRequests < ActiveRecord::Migration[8.0]
  # The user -> captain direction. Invitation is captain -> user and validates
  # recepient_is_not_member_of_any_team, a rule three frozen scenarios in
  # features/invitations/send-invitations.feature pin -- so a transfer request
  # cannot ride it without relaxing exactly what they freeze.
  def change
    create_table :team_join_requests do |t|
      t.integer :user_id, null: false
      t.integer :team_id, null: false
      # Same vocabulary as game_entries: "new" until the target team's captain
      # decides, then "accepted" or "rejected".
      t.string  :status,  null: false, default: "new"
      t.timestamps
    end

    add_index :team_join_requests, [ :team_id, :status ]

    # Scoped to the live status rather than a blanket unique index, mirroring
    # index_game_entries_on_team_id_and_game_id_live and for the same reason.
    # A blanket index would reject legitimate history -- an applicant the
    # captain refused could never apply again -- while this one forbids only
    # the actual bug: a double-clicked button, or two near-simultaneous
    # requests, creating a second live row for one (user_id, team_id).
    add_index :team_join_requests, [ :user_id, :team_id ],
              unique: true,
              where: "status = 'new'",
              name: "index_team_join_requests_on_user_id_and_team_id_pending"
  end
end
