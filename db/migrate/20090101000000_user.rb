# -*- encoding : utf-8 -*-
class User < ActiveRecord::Migration[4.2]
  def self.up
    create_table :users do |t|
      t.string :email
      t.string :name
      t.string :crypted_password
      t.string :salt
      t.timestamps null: false
    end
  end

  def self.down
    drop_table :users
  end
end
