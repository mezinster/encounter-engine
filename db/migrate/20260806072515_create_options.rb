class CreateOptions < ActiveRecord::Migration[8.0]
  def change
    create_table :options do |t|
      t.integer :question_id, null: false
      t.string  :text,        null: false
      # A wrong option is the default. An author marks what is true, and the
      # question type follows from how many are marked -- there is no separate
      # mode column that could disagree.
      t.boolean :is_correct, null: false, default: false
      t.integer :position
      t.timestamps
    end

    add_index :options, :question_id
  end
end
