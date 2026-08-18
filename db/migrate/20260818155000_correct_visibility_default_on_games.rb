# The default set in 20260818110000_add_visibility_to_games.rb was the wrong
# polarity: the column it replaced, is_draft, was `default: false` -- a new
# Game was PUBLISHED, not a draft. Giving visibility a default of "draft"
# inverted that, and because the author form's checkbox
# (f.check_box :visibility, {}, "draft", "listed") renders checked whenever
# the object's current value equals "draft", every game created through the
# form without touching the checkbox silently became a draft. See the
# regression report for the acceptance-suite fallout.
#
# This migration only fixes the DEFAULT applied to new rows going forward.
# It does not touch existing rows or the backfill in the add-column
# migration, which is unaffected and untouched.
class CorrectVisibilityDefaultOnGames < ActiveRecord::Migration[8.0]
  def up
    change_column_default :games, :visibility, from: "draft", to: "listed"
  end

  def down
    change_column_default :games, :visibility, from: "listed", to: "draft"
  end
end
