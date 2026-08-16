# One AI translation run, and the proposals it produced.
#
# Two tables rather than writing straight into content_translations: nothing
# reaches a live game without a human action, so the publication gate
# (Game#declared_locales_are_translated_before_publication) can never be
# satisfied by text nobody looked at.
class CreateTranslationRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :translation_runs do |t|
      t.integer  :game_id,  :null => false
      t.integer  :actor_id, :null => false

      # Resolved from Setting at start time, then FROZEN on the row. Read live
      # instead and changing the setting mid-run yields a run whose proposals
      # came from two different models with no way to tell which is which.
      t.string   :model, :null => false

      t.string   :state, :null => false, :default => "pending"

      # Comma-joined, matching games.available_locales: a short list of ASCII
      # locale codes that has to be readable in a console during an incident.
      t.string   :target_locales, :null => false, :default => ""

      t.integer  :fields_total,  :null => false, :default => 0
      t.integer  :fields_done,   :null => false, :default => 0
      t.integer  :fields_failed, :null => false, :default => 0

      t.integer  :estimated_input_tokens, :null => false, :default => 0
      t.integer  :input_tokens,           :null => false, :default => 0
      t.integer  :output_tokens,          :null => false, :default => 0
      # Kept so the run page can show whether the prompt-caching structure in
      # the design's §3 is actually hitting, rather than the design merely
      # asserting that it does.
      t.integer  :cache_read_tokens,      :null => false, :default => 0

      t.text     :error_message
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :translation_runs, [ :game_id, :state ]

    create_table :translation_proposals do |t|
      t.integer  :translation_run_id, :null => false
      t.string   :translatable_type,  :null => false
      t.integer  :translatable_id,    :null => false
      t.string   :field,  :null => false
      t.string   :locale, :null => false

      # SNAPSHOTTED at translation time, for the same reason
      # AdminAction#target_label snapshots its target's name: if the level text
      # is later edited, a proposal that only pointed at the record would
      # silently start claiming to be a translation of text that no longer
      # exists. The snapshot is what makes this an audit trail, not a cache.
      t.text     :source_text,   :null => false
      t.text     :proposed_text, :null => false

      t.string   :flags
      t.string   :state, :null => false, :default => "pending"
      t.integer  :reviewed_by_id
      t.datetime :reviewed_at
      t.timestamps
    end

    # NOT hygiene. This index is the resumability mechanism: the runner skips
    # any (record, field, locale) that already has a proposal for this run, so
    # a thread killed by a deploy costs the level in flight, not the run.
    add_index :translation_proposals,
              [ :translation_run_id, :translatable_type, :translatable_id, :field, :locale ],
              :unique => true, :name => "index_translation_proposals_unique_field"
    add_index :translation_proposals, [ :translation_run_id, :state ]
  end
end
