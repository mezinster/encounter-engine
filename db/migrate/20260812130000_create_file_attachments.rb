# What a game file is attached to.
#
# Polymorphic on purpose: it mirrors ContentTranslation's
# `belongs_to :translatable, polymorphic: true`, so levels and hints share one
# association and a third owner later costs nothing.
class CreateFileAttachments < ActiveRecord::Migration[8.0]
  def change
    create_table :file_attachments do |t|
      t.integer :game_file_id, :null => false
      t.string  :attachable_type, :null => false
      t.integer :attachable_id, :null => false
      # NULL means "show in every language", which is what every file gets by
      # default -- a photograph of a building has no language. A non-null
      # value scopes the attachment to one locale, for the rare case of a map
      # whose labels are translated.
      t.string  :locale
      t.integer :position
      t.timestamps
    end

    add_index :file_attachments, [ :attachable_type, :attachable_id ]
    add_index :file_attachments, :game_file_id
  end
end
