require "rails_helper"

describe Game, "#missing_translated_fields_in" do
  let(:game) do
    create_game(:primary_locale => "ru", :available_locale_list => %w[ru]).tap do |g|
      create_level(:game => g, :name => "Первый", :text => "Найдите табличку")
    end
  end

  # The whole point of the extraction: a locale that is not declared yet still
  # produces a work-list, so a superadmin can translate first and declare
  # second. missing_translations returns nothing here, correctly.
  it "returns work for a locale the game has not declared" do
    expect(game.missing_translations).to be_empty

    fields = game.missing_translated_fields_in("pl")

    expect(fields.map(&:field)).to match_array(%w[name description name text])
    expect(fields.map(&:locale).uniq).to eq([ "pl" ])
  end

  it "skips fields that already have a usable translation" do
    level = game.levels.first
    level.translations_attributes = { "pl" => { "name" => "Pierwszy" } }
    level.save!

    fields = game.missing_translated_fields_in("pl")

    expect(fields.select { |f| f.record == level }.map(&:field)).to eq([ "text" ])
  end

  it "labels every entry, so no blank instruction reaches the author's list" do
    expect(game.missing_translated_fields_in("pl").map(&:label)).to all(be_present)
  end

  # The review screen renders this from a view, so it has to be public. It is
  # not snapshotted onto the proposal row on purpose: the label is derived from
  # position and field name, and should render in the READER's locale rather
  # than in whichever locale the run happened to start in.
  it "exposes label_for publicly" do
    level = game.levels.first

    expect(game.label_for(level, "text")).to be_present
    expect { game.public_send(:label_for, level, "text") }.not_to raise_error
  end

  # Regression guard on the extraction: missing_translations must keep
  # answering exactly as before, because the publish gate depends on it.
  #
  # create_game leaves visibility at the fixture's default ("listed", i.e.
  # published), and declared_locales_are_translated_before_publication
  # already blocks a PUBLISHED game from declaring a locale it hasn't
  # translated yet -- that gate is pre-existing behaviour, unrelated to this
  # extraction, and exactly what tests 1-3 above show being solved a
  # different way (translate before declaring). Moving to a draft first, in
  # its own update!, sidesteps it: the gate's `return if self.draft?` reads
  # the value being saved, and this call changes only visibility (no
  # available_locales change), so it never reaches the branch that blocks on
  # missing translations. That isolates the one thing this example exists to
  # check: that missing_translations still answers only for declared locales.
  it "leaves missing_translations answering for declared locales only" do
    game.update!(:visibility => "draft")
    game.update!(:available_locale_list => %w[ru pl])

    expect(game.missing_translations.map(&:locale).uniq).to eq([ "pl" ])
    expect(game.missing_translations.size).to eq(game.missing_translated_fields_in("pl").size)
  end
end
