class CreateGameLocalePreferences < ActiveRecord::Migration[8.0]
  def change
    create_table :game_locale_preferences do |t|
      t.integer :user_id, null: false
      t.integer :game_id, null: false
      t.string  :locale,  null: false
      t.timestamps
    end
    add_index :game_locale_preferences, %i[user_id game_id], unique: true
  end
end
