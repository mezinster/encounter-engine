# -*- encoding : utf-8 -*-
class AddNameToLevels < ActiveRecord::Migration[4.2]
  def self.up
    add_column :levels, :name, :string
  end

  def self.down
    remove_column :levels, :name
  end
end
