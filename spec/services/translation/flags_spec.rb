require "rails_helper"

describe Translation::Flags do
  def flags_for(source, proposed)
    described_class.for(:source => source, :proposed => proposed)
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
end
