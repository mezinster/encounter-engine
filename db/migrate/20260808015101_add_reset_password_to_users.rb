class AddResetPasswordToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :reset_password_token_digest, :string
    add_column :users, :reset_password_sent_at, :datetime
    add_index  :users, :reset_password_token_digest
  end
end
