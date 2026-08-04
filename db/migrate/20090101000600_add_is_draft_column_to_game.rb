# -*- encoding : utf-8 -*-
class AddIsDraftColumnToGame < ActiveRecord::Migration[4.2]
  def self.up
    add_column :games, :is_draft, :boolean, :null => false, :default => false
  end

  def self.down
    remove_column :games, :is_draft
  end
end
