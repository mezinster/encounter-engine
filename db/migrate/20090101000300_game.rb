# -*- encoding : utf-8 -*-
class Game < ActiveRecord::Migration[4.2]
  def self.up
    create_table :games do |t|
      t.string :name
      t.string :description
      t.integer :author_id
      t.timestamps null: false
    end
  end

  def self.down
    drop_table :games
  end
end
