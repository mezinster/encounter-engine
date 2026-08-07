class AddContactFieldsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :instagram,   :string
    add_column :users, :telegram_id, :string

    add_column :users, :on_telegram, :boolean, :default => false, :null => false
    add_column :users, :on_whatsapp, :boolean, :default => false, :null => false
    add_column :users, :on_viber,    :boolean, :default => false, :null => false
    add_column :users, :on_signal,   :boolean, :default => false, :null => false
    add_column :users, :on_max,      :boolean, :default => false, :null => false
  end
end
