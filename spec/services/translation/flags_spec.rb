require "rails_helper"

describe Translation::Flags do
  # source_locale defaults to the game language every example here was written
  # against; the examples that care about it pass their own.
  def flags_for(source, proposed, source_locale: "ru")
    described_class.for(:source => source, :proposed => proposed,
                        :source_locale => source_locale)
  end

  it "returns nothing for an ordinary good translation" do
    expect(flags_for("Найдите табличку на стене", "Find the sign on the wall")).to eq([])
  end

  it "flags empty and whitespace-only output" do
    expect(flags_for("Найдите табличку", "")).to include("empty")
    expect(flags_for("Найдите табличку", "   \n ")).to include("empty")
  end

  # THE important one. This is the failure translatable_content.rb:49-62
  # documents: text saved unchanged in another language's slot, which then
  # satisfies the publish gate. An automated translator that echoes its input
  # reproduces that at scale.
  it "flags output byte-identical to the source" do
    expect(flags_for("Найдите табличку", "Найдите табличку")).to include("identical")
  end

  it "ignores surrounding whitespace when deciding identity" do
    expect(flags_for("Найдите табличку", "  Найдите табличку  ")).to include("identical")
  end

  # `identical` asks "did the model fail to translate this?", and that question
  # is only meaningful when the source held something translatable in the first
  # place. A quiz option that is a brand name or a number comes back unchanged
  # because unchanged is CORRECT, and one real run produced 15 of them
  # (Gucci, YouTube, 17, ...) against 483 clean proposals -- noise that a
  # reviewer has to clear by hand, on exactly the check whose value depends on
  # being rare enough to read.
  describe "a source with nothing in the game's own language to translate" do
    it "does not call an unchanged brand name identical" do
      expect(flags_for("Gucci", "Gucci")).not_to include("identical")
    end

    it "does not call an unchanged number identical" do
      expect(flags_for("17", "17")).not_to include("identical")
    end

    # THE regression guard for this rule: the suppression must not reach the
    # failure `identical` exists for -- Russian text echoed back as its own
    # translation, which then satisfies the publish gate.
    it "still flags source-language text echoed back unchanged" do
      expect(flags_for("Орёл сел", "Орёл сел")).to include("identical")
    end

    it "reads the script from the game's language, not from the alphabet at hand" do
      expect(flags_for("გუჩი", "გუჩი", :source_locale => "ka")).to include("identical")
      expect(flags_for("Gucci", "Gucci", :source_locale => "ka")).not_to include("identical")
    end

    # A game authored in a Latin-script language cannot be helped by this test:
    # "Gucci" and an untranslated English sentence look the same to it. Pinned
    # so the limitation is a decision on record rather than a surprise.
    it "cannot tell a brand name from untranslated text in a Latin-script game" do
      expect(flags_for("Gucci", "Gucci", :source_locale => "en")).to include("identical")
    end

    # available_locales can grow without anyone remembering this file, so an
    # unregistered locale must not silently switch the check off. It falls back
    # to "any letter at all", which is the old behaviour except for sources
    # that are pure digits.
    it "falls back to any letter for a locale it does not know" do
      expect(flags_for("Gucci", "Gucci", :source_locale => "xx")).to include("identical")
      expect(flags_for("17", "17", :source_locale => "xx")).not_to include("identical")
    end
  end

  # Answers in this game are codes players type. Translating one silently
  # breaks the game for every team.
  it "flags a digit sequence present in the source but missing from the output" do
    expect(flags_for("Код на двери: 4417", "The code on the door")).to include("lost_digits")
  end

  it "does not flag digits that survived" do
    expect(flags_for("Код на двери: 4417", "The door code is 4417")).not_to include("lost_digits")
  end

  it "flags a Latin-script token present in the source but missing from the output" do
    expect(flags_for("Ищите вывеску BETA", "Look for the sign")).to include("lost_latin")
  end

  it "does not flag Latin tokens introduced by the translation itself" do
    expect(flags_for("Найдите табличку", "Find the sign")).not_to include("lost_latin")
  end

  it "flags output far shorter or far longer than the source" do
    source = "а" * 100
    expect(flags_for(source, "б" * 30)).to include("length")
    expect(flags_for(source, "б" * 300)).to include("length")
    expect(flags_for(source, "б" * 100)).not_to include("length")
  end

  it "does not raise the length flag on very short source strings" do
    expect(flags_for("Да", "Yes")).not_to include("length")
  end

  # NOTE: the brief's original example here was flags_for("Код 4417", ""),
  # expecting match_array(%w[empty length]). That combination is structurally
  # impossible under the brief's own implementation: an empty `proposed` can
  # never contain the source's digits, so `lost_digits` necessarily fires
  # alongside `empty` whenever the source has any digit run -- and "Код 4417"
  # is 8 characters, below MIN_LENGTH_FOR_RATIO, so `length` would not even
  # fire. Swapped in a source with no digits/Latin and length >= 20 so the
  # same intent (multiple flags at once) is actually reachable.
  it "can return several flags at once" do
    expect(flags_for("Найдите табличку на стене подъезда", "")).to match_array(%w[empty length])
  end

  # String#strip trims ASCII whitespace only, so a lone non-breaking space --
  # which machine output can plausibly contain -- escaped `empty` entirely and
  # compared unequal in `identical`. Both are checks that exist to catch
  # exactly this shape of output, and both let it through.
  describe "whitespace that String#strip does not see" do
    NBSP = " ".freeze

    it "treats a lone non-breaking space as empty" do
      expect(flags_for("Найдите табличку", NBSP)).to include("empty")
    end

    it "sees through non-breaking padding when comparing against the source" do
      expect(flags_for("Найдите табличку", "#{NBSP}Найдите табличку#{NBSP}")).to include("identical")
    end

    it "does not call a real translation empty just because it is padded" do
      expect(flags_for("Найдите табличку", "#{NBSP}Find the sign#{NBSP}")).not_to include("empty")
    end
  end
end
