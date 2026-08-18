class CreateAccessCodes < ActiveRecord::Migration[8.0]
  def change
    create_table :access_codes do |t|
      t.integer  :game_id,     :null => false
      # Only the digest is ever stored. The raw code is shown once, at
      # generation, and cannot be recovered from here -- which is why the
      # operator console has a lookup box the customer's own code is typed
      # into. See the design, C3 and C12.
      t.string   :code_digest, :null => false
      # A handle, not a secret: it identifies a print run and grants nothing,
      # so it is safe on screen and in an AdminAction's details.
      t.string   :batch_key,   :null => false
      t.integer  :issued_by_id
      t.datetime :revoked_at
      t.datetime :expires_at
      t.datetime :redeemed_at
      t.integer  :access_pass_id
      t.timestamps
    end

    add_index :access_codes, :code_digest, :unique => true
    add_index :access_codes, [ :game_id, :batch_key ]
  end
end
