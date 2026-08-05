class AddLocalesToGames < ActiveRecord::Migration[8.0]
  def change
    # Existing games were authored in Russian, so that is the honest default.
    add_column :games, :primary_locale,    :string, default: "ru", null: false
    # Comma-separated; always contains primary_locale (validated on Game).
    add_column :games, :available_locales, :string, default: "ru", null: false
  end
end
