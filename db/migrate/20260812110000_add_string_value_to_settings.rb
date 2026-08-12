# Settings held integers only -- the four rate limits. The allowed-extensions
# list for game file uploads is strings, and it belongs on the same admin page
# and in the same audit trail, so the table grows a second value column rather
# than the application growing a second settings mechanism.
#
# Nullable: an integer setting has no string_value and a string setting has no
# value, and which one is meaningful is decided by the key, not by the row.
class AddStringValueToSettings < ActiveRecord::Migration[8.0]
  def up
    add_column :settings, :string_value, :string
    change_column_null :settings, :value, true
  end

  # Explicit, because the auto-generated inverse of change_column_null is
  # change_column_null :settings, :value, false -- and that FAILS on both
  # SQLite and PostgreSQL as soon as any row has value IS NULL, which is every
  # string-key row by construction (Setting.put never sets `value` for those).
  # Phase 1 shipped this as `change` with a warning comment; phase 2 is what
  # wires the admin form to write string settings, so this is where the warning
  # has to become working code.
  #
  # Deleting the string rows is correct rather than destructive: they hold
  # operator settings that have shipped defaults in the model, so a row's
  # absence restores the default. The alternative -- refusing to roll back --
  # leaves an operator stuck mid-incident.
  def down
    execute("DELETE FROM settings WHERE value IS NULL")
    change_column_null :settings, :value, false
    remove_column :settings, :string_value
  end
end
