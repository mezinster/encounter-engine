class CreateAdminActions < ActiveRecord::Migration[8.0]
  def change
    create_table :admin_actions do |t|
      t.integer  :actor_id,    null: false
      t.string   :action,      null: false
      # Nullable: not every action has a target.
      t.string   :target_type
      t.integer  :target_id
      # The target's name AT THE TIME. See the model comment.
      t.string   :target_label
      # created_at only, deliberately: rows are never updated, so an
      # updated_at column would imply a capability this table must not have.
      t.datetime :created_at, null: false
    end

    add_index :admin_actions, :created_at
    add_index :admin_actions, :actor_id
  end
end
