class AddSessionTokenToUsers < ActiveRecord::Migration[8.0]
  def up
    add_column :users, :session_token, :string

    # Backfill so every existing row has one. Rows left null would authenticate
    # against a null token, which is exactly the check this column exists to
    # perform.
    User.reset_column_information
    User.find_each { |user| user.update_column(:session_token, SecureRandom.hex(20)) }
  end

  def down
    remove_column :users, :session_token
  end
end
