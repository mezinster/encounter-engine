# -*- encoding : utf-8 -*-
class RenameNameToNickname < ActiveRecord::Migration[4.2]
  def self.up
    rename_column :users, :name, :nickname
  end

  def self.down
    rename_column :users, :nickname, :name
  end
end
