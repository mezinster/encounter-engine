# The reviewer's text, kept apart from the machine's.
#
# Editing before accepting used to overwrite proposed_text, which destroyed the
# one thing this table exists to record. The design argues (§1) that the
# source_text snapshot "is what makes the table an audit trail rather than a
# cache", and (§5) that provenance lives ONLY here -- the game never reads it.
# Overwriting proposed_text broke both claims at once: the table could no
# longer answer "what did the machine actually produce", and `flags`, computed
# against the original, stayed attached to text it was never computed from.
#
# Nullable: a proposal accepted unedited has no accepted_text, and that
# absence is itself the record that the reviewer changed nothing.
class AddAcceptedTextToTranslationProposals < ActiveRecord::Migration[8.0]
  def change
    add_column :translation_proposals, :accepted_text, :text
  end
end
