# -*- encoding : utf-8 -*-
class AddOrderToLevel < ActiveRecord::Migration[4.2]
  def self.up
    add_column :levels, :order, :integer
  end

  def self.down
    remove_column :levels, :order
  end
end
