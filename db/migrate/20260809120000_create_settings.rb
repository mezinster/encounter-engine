class CreateSettings < ActiveRecord::Migration[8.0]
  # Name/value rather than one column per setting: the set of knobs will grow,
  # and a column per knob means a migration and a deploy for each one -- which
  # is exactly the deploy this table exists to avoid.
  #
  # No seed rows. Defaults live in Setting::DEFAULTS, so a fresh database, a
  # restored one and a test transaction all behave identically, and deleting a
  # row is a safe way back to the shipped value.
  def change
    create_table :settings do |t|
      t.string  :name,  :null => false
      t.integer :value, :null => false
      t.timestamps
    end

    add_index :settings, :name, :unique => true
  end
end
