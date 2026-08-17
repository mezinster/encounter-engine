require "rails_helper"

# The pre-flight estimate, whose cost in API round trips must NOT grow with the
# size of the game.
#
# It used to be one count_tokens call per unit per locale, run synchronously
# inside the POST that renders the confirmation screen: 71 calls for a 70-level
# quiz at one language, ~426 at six. The 400-field cap was the only thing
# keeping that from ever being reached -- which is why this had to be fixed
# before the cap could be raised.
describe Translation::Runner, ".estimate_input_tokens" do
  # Records every call so the COUNT can be asserted. A spec that checked only
  # the returned number would pass just as happily with the old
  # O(units x locales) loop still in place, which is the whole bug.
  class CountingClient
    attr_reader :calls

    # Shaped like the arithmetic assumes: a baseline call prices the rules
    # prefix plus the instruction, and a bulk call prices that plus the sources.
    BASELINE = 40
    SOURCES  = 500

    def initialize
      @calls = []
    end

    def count_input_tokens(unit:, locale:)
      @calls << [ unit.key, locale, unit.source_text.length ]
      unit.key == "estimate:baseline" ? BASELINE : BASELINE + SOURCES
    end
  end

  def game_with(levels:)
    game = create_game(:primary_locale => "ru", :available_locale_list => %w[ru])
    levels.times { |i| create_level(:game => game, :name => "Уровень #{i}", :text => "Текст #{i}") }
    game
  end

  it "issues one baseline call per locale plus one bulk call" do
    client = CountingClient.new
    described_class.estimate_input_tokens(game_with(:levels => 5), %w[en pl], :client => client)

    expect(client.calls.size).to eq(3)
    expect(client.calls.map(&:first)).to eq(
      [ "estimate:baseline", "estimate:baseline", "estimate:bulk" ]
    )
  end

  # THE assertion. The old implementation's call count was a function of level
  # count; the new one's must not be. Ten times the game, the same three calls.
  it "does not make more calls when the game gets bigger" do
    small = CountingClient.new
    big   = CountingClient.new

    described_class.estimate_input_tokens(game_with(:levels => 3),  %w[en], :client => small)
    described_class.estimate_input_tokens(game_with(:levels => 30), %w[en], :client => big)

    expect(big.calls.size).to eq(small.calls.size)
  end

  # total = n_units x SUM(baselines) + n_locales x SUM(source tokens)
  #
  # 6 units = 1 game header + 5 levels. The header unit always exists here
  # because build_game sets BOTH name and description, so the game's own two
  # translatable fields are always in the work-list; a game with neither would
  # produce 5 units and this total would be 400 + 1000.
  #
  # 6 x (40 + 40) + 2 x 500 = 480 + 1000 = 1480
  it "computes the closed form over units and locales" do
    total = described_class.estimate_input_tokens(
      game_with(:levels => 5), %w[en pl], :client => CountingClient.new
    )

    expect(total).to eq(1480)
  end

  it "sends a non-empty baseline source, because the API rejects an empty text block" do
    client = CountingClient.new
    described_class.estimate_input_tokens(game_with(:levels => 2), %w[en], :client => client)

    baseline = client.calls.find { |key, _locale, _length| key == "estimate:baseline" }
    expect(baseline.last).to be > 0
  end

  it "costs nothing when every requested locale is the primary one" do
    client = CountingClient.new

    expect(described_class.estimate_input_tokens(game_with(:levels => 3), %w[ru], :client => client))
      .to eq(0)
    expect(client.calls).to be_empty
  end

  # One bulk call over every source concatenated is fine for a 70-level quiz and
  # not fine without bound: a large enough game would exceed the model's input
  # limit and the estimate would fail. Failing renders "unknown" rather than
  # blocking the run, but it loses the cost guard, which is the point of the
  # screen.
  describe "very large games" do
    # Forced small so the split is reachable without building a game carrying
    # megabytes of source text.
    before { stub_const("Translation::Runner::BULK_SOURCE_CHARS", 120) }

    it "splits the bulk call rather than sending one unbounded prompt" do
      client = CountingClient.new
      described_class.estimate_input_tokens(game_with(:levels => 10), %w[en], :client => client)

      bulk = client.calls.select { |key, _locale, _length| key == "estimate:bulk" }
      expect(bulk.size).to be > 1
      # No piece may exceed the limit, allowing for the "\n\n" joins between
      # units within a piece.
      expect(bulk.map(&:last)).to all(be <= 120 + 60)
    end

    it "still counts every source exactly once across the pieces" do
      client = CountingClient.new
      total  = described_class.estimate_input_tokens(game_with(:levels => 10), %w[en], :client => client)

      # Each bulk piece returns BASELINE + SOURCES and contributes SOURCES once
      # its baseline is subtracted, so the sources term is pieces x SOURCES.
      pieces = client.calls.count { |key, _locale, _length| key == "estimate:bulk" }
      units  = 11 # 1 game header + 10 levels
      expect(total).to eq(units * CountingClient::BASELINE + pieces * CountingClient::SOURCES)
    end

    it "keeps the call count independent of unit count even when splitting" do
      client = CountingClient.new
      described_class.estimate_input_tokens(game_with(:levels => 10), %w[en], :client => client)

      # One baseline plus a small number of pieces -- emphatically not 11.
      expect(client.calls.size).to be < 11
    end
  end

  describe ".bulk_groups" do
    it "gives a unit larger than the limit a group of its own" do
      stub_const("Translation::Runner::BULK_SOURCE_CHARS", 10)
      units = [ Translation::Unit.raw("a", "x" * 50),
                Translation::Unit.raw("b", "y" * 50) ]

      groups = described_class.bulk_groups(units)

      expect(groups.size).to eq(2)
      expect(groups.map(&:size)).to eq([ 1, 1 ])
    end

    it "packs units that fit together into one group" do
      stub_const("Translation::Runner::BULK_SOURCE_CHARS", 100)
      units = [ Translation::Unit.raw("a", "x" * 10),
                Translation::Unit.raw("b", "y" * 10) ]

      expect(described_class.bulk_groups(units).size).to eq(1)
    end
  end
end
