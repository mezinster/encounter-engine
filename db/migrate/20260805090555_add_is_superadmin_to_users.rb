class AddIsSuperadminToUsers < ActiveRecord::Migration[8.0]
  def change
    # Defaulted and non-null, so every existing row is valid without a backfill
    # and nobody gains the role by accident.
    add_column :users, :is_superadmin, :boolean, default: false, null: false
  end
end
