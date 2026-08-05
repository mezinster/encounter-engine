class CreateContentTranslations < ActiveRecord::Migration[8.0]
  def change
    create_table :content_translations do |t|
      t.string  :translatable_type, null: false
      t.integer :translatable_id,   null: false
      t.string  :field,             null: false
      t.string  :locale,            null: false
      t.text    :value
      t.timestamps
    end
    add_index :content_translations,
              %i[translatable_type translatable_id field locale],
              unique: true, name: "index_content_translations_uniqueness"
  end
end
