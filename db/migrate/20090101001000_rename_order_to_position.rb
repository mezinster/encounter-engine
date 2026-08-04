# -*- encoding : utf-8 -*-
class RenameOrderToPosition < ActiveRecord::Migration[4.2]
  def self.up
    rename_column :levels, :order, :position
  end

  def self.down
    rename_column :levels, :position, :order
  end
end
