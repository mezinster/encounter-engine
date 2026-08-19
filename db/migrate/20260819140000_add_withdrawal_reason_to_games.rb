class AddWithdrawalReasonToGames < ActiveRecord::Migration[8.0]
  def change
    # Nullable: they describe the CURRENT withdrawal and are cleared on
    # restore. A game withdrawn twice keeps no record of the first -- the audit
    # log does.
    add_column :games, :withdrawal_category, :string
    add_column :games, :withdrawal_note,     :text
    add_column :games, :withdrawal_mode,     :string

    # Whether THIS withdrawal paused the run. Without it, restore cannot tell a
    # pause it caused from one the operator made before withdrawing, and would
    # either double-count the held interval or un-pause a game the operator
    # meant to stay paused.
    add_column :games, :withdrawal_paused_run, :boolean, :null => false, :default => false
  end
end
