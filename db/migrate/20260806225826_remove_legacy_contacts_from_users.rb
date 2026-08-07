class RemoveLegacyContactsFromUsers < ActiveRecord::Migration[8.0]
  def change
    # Reversible -- the type is given, so db:rollback restores the columns.
    # It restores them EMPTY: the stored values are destroyed, decided
    # explicitly by the repository owner rather than exported first.
    remove_column :users, :icq_number, :string
    remove_column :users, :jabber_id,  :string
  end
end
