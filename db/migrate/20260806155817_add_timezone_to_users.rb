class AddTimezoneToUsers < ActiveRecord::Migration[8.0]
  def change
    # Nullable, no default, no backfill. NULL means "use the instance default",
    # which is what lets every existing user keep rendering exactly as they do
    # today without touching a single row -- and it keeps "never chose one"
    # distinguishable from "chose the instance zone".
    add_column :users, :timezone, :string
  end
end
