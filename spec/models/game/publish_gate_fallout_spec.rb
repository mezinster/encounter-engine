# spec/models/game/publish_gate_fallout_spec.rb
#
# Whole-branch review, Finding 1 (CRITICAL): the publish gate used to run on
# EVERY Game#save (a state-only `return if draft?` check), not just on
# publication-relevant changes. That made a published multilingual game
# permanently invalid the moment anything else about it was saved --
# including changes that have nothing to do with translation. These specs
# pin the three call sites the reviewer found broken. Each one arranges a
# genuine translation gap (an untranslated level added AFTER the game
# published cleanly) before exercising the method, because the old guard
# was only ever wrong when a gap actually existed at save time -- a fixture
# with no gap can't tell the old guard from the new one:
#   - adding a level to an already-published, already-translated game
#   - reserve_place_for_team!, which uses a bare `save` and silently
#     swallowed the failure, so requested_teams_number stopped moving and
#     max_team_number became unenforceable
#   - free_place_of_team!, the same bare-`save` failure mode in reverse
#   - finish_game!, which uses `save!` and would 500 the author trying to
#     end their own game
require "rails_helper"

describe Game do
  let(:game) do
    g = create_game(:is_draft => true)
    g.available_locale_list = %w[ru en]
    g.translations_attributes = { "en" => { "name" => "#{g.name} (EN)",
                                            "description" => "#{g.description} (EN)" } }
    g.save!
    level = create_level(:game => g, :name => "Уровень", :text => "Текст")
    level.translations_attributes = { "en" => { "name" => "Level", "text" => "Text" } }
    level.save!
    g.update!(:is_draft => false)
    g
  end

  describe "publication-relevant-only gate, fallout" do
    it "leaves a published multilingual game valid and saveable after adding a new, untranslated level" do
      expect(game).to be_valid

      new_level = create_level(:game => game, :name => "Уровень 2", :text => "Текст 2")
      expect(new_level).to be_persisted

      reloaded = game.reload
      expect(reloaded).to be_valid
      expect(reloaded.update(:max_team_number => reloaded.max_team_number + 1)).to be true
    end

    it "still lets reserve_place_for_team! increment requested_teams_number on a published multilingual game with a translation gap" do
      create_level(:game => game, :name => "Уровень 2", :text => "Текст 2")
      game.reload

      expect do
        game.reserve_place_for_team!
      end.to change { game.reload.requested_teams_number }.by(1)
    end

    it "still lets free_place_of_team! decrement requested_teams_number on a published multilingual game with a translation gap" do
      game.reserve_place_for_team!
      create_level(:game => game, :name => "Уровень 2", :text => "Текст 2")
      game.reload

      expect do
        game.free_place_of_team!
      end.to change { game.reload.requested_teams_number }.by(-1)
    end

    it "does not raise when finish_game! is called on a published multilingual game with a translation gap" do
      create_level(:game => game, :name => "Уровень 2", :text => "Текст 2")
      game.reload

      expect { game.finish_game! }.not_to raise_error
      expect(game.reload.author_finished?).to be true
    end
  end

  # Whole-branch review, Finding 1's locale gap: ActiveRecord::RecordInvalid#
  # initialize builds its message from I18n.t("activerecord.errors.messages.
  # record_invalid", ...), a key this app never defined. Reproduced by the
  # reviewer as `save!` on an invalid record rendering "Translation missing:
  # ru.activerecord.errors.messages.record_invalid" instead of a real message
  # -- reachable the moment #save! hits a validation failure, which this
  # feature made more likely by adding the publish-gate validation.
  describe "activerecord.errors.messages.record_invalid" do
    it "renders a real message, not a translation-missing placeholder, when save! fails" do
      invalid_game = Game.new

      expect { invalid_game.save! }.to raise_error(ActiveRecord::RecordInvalid) do |error|
        expect(error.message).not_to include("Translation missing")
        expect(error.message).to include("Запись недействительна")
      end
    end
  end
end
