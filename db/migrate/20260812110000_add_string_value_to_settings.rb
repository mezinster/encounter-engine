# Settings held integers only -- the four rate limits. The allowed-extensions
# list for game file uploads is strings, and it belongs on the same admin page
# and in the same audit trail, so the table grows a second value column rather
# than the application growing a second settings mechanism.
#
# Nullable: an integer setting has no string_value and a string setting has no
# value, and which one is meaningful is decided by the key, not by the row.
class AddStringValueToSettings < ActiveRecord::Migration[8.0]
  # WARNING for a rollback during an incident: change_column_null's
  # auto-generated inverse for the `value` line is
  # change_column_null :settings, :value, false -- and that inverse FAILS, on
  # both SQLite and PostgreSQL, as soon as any row has value IS NULL. That
  # happens as soon as a single string key is stored: Setting.put never sets
  # `value` for a STRING_DEFAULTS key (see app/models/setting.rb), so a string
  # setting row has value IS NULL by construction. This migration is inert
  # until Phase 2 wires the admin form to write string settings; once it does,
  # `bin/rails db:rollback` on this migration will raise rather than undo
  # cleanly. Fixing this means an explicit up/down (Phase 2's job, not this
  # one) -- don't "fix" it here by converting to explicit up/down; just know
  # this before reaching for rollback.
  def change
    add_column :settings, :string_value, :string
    change_column_null :settings, :value, true
  end
end
