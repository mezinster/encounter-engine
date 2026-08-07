class AddAnyCodePassesToLevels < ActiveRecord::Migration[8.0]
  def change
    # Two steps, deliberately. add_column with a default BACKFILLS every
    # existing row, so the default has to start false to leave live games
    # exactly as they are; only then is it flipped for rows created afterwards.
    # A single statement cannot express "existing rows false, new rows true".
    add_column :levels, :any_code_passes, :boolean, :default => false, :null => false
    change_column_default :levels, :any_code_passes, :from => false, :to => true
  end
end
