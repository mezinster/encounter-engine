# Settings held integers only -- the four rate limits. The allowed-extensions
# list for game file uploads is strings, and it belongs on the same admin page
# and in the same audit trail, so the table grows a second value column rather
# than the application growing a second settings mechanism.
#
# Nullable: an integer setting has no string_value and a string setting has no
# value, and which one is meaningful is decided by the key, not by the row.
class AddStringValueToSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :settings, :string_value, :string
    change_column_null :settings, :value, true
  end
end
