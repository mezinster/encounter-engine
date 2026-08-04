# -*- encoding : utf-8 -*-
class EndGame < ActiveRecord::Migration[4.2]
  def self.up
    add_column :game_passings, :status, :string
    add_column :games, :author_finished_at, :datetime
  end

  def self.down
    remove_column :game_passings, :status
    remove_column :games, :author_finished_at
  end
end
