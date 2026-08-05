class AddDetailsToAdminActions < ActiveRecord::Migration[8.0]
  def change
    # Nullable and nil for every action recorded so far. AdminAction carries a
    # single target, so a team-scoped intervention can name the game or the
    # team but not both; this holds the team alongside a Game target.
    add_column :admin_actions, :details, :string
  end
end
