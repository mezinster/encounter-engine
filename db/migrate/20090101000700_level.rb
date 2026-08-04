# -*- encoding : utf-8 -*-
class Level < ActiveRecord::Migration[4.2]
  def self.up
    create_table :levels do |t|
      t.text :text
      t.string :correct_answers
      t.integer :game_id
      t.timestamps null: false
    end
  end

  def self.down
    drop_table :levels
  end
end
