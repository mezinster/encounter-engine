class AddOperatorToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :is_operator, :boolean, :default => false, :null => false
  end
end
