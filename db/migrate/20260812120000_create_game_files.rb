# One uploaded file in one game's library. A Game is the CONTENT, so its files
# are content too: every run of the game shows the same photos, which is why
# this hangs off game_id and not game_run_id.
#
# See docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md §1.
class CreateGameFiles < ActiveRecord::Migration[8.0]
  def change
    create_table :game_files do |t|
      t.integer :game_id, :null => false
      # The name the AUTHOR sees. Never a path: Active Storage names the bytes
      # on disk by opaque key, so "../../etc/passwd" here is inert.
      t.string  :filename, :null => false
      # Sniffed from the file's own leading bytes, never taken from the
      # request header or the extension -- both are attacker-controlled.
      t.string  :content_type, :null => false
      # Size AFTER canonicalisation, not as uploaded: a 4 MB HEIC becomes a
      # 1.1 MB JPEG and it is the JPEG that occupies the disk.
      t.integer :byte_size, :null => false, :default => 0
      # Sum of the generated web/thumb variants. Counted against the quota
      # because they are equally real on the disk.
      t.integer :derived_byte_size, :null => false, :default => 0
      t.string  :checksum
      t.integer :uploaded_by_id
      t.timestamps
    end

    add_index :game_files, :game_id
    # Unique per game, not globally: two games may each have their own дом.jpg.
    add_index :game_files, [ :game_id, :filename ], :unique => true
  end
end
