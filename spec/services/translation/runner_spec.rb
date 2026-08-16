require "rails_helper"

describe Translation::Runner do
  let(:actor)  { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)   { create_game(:primary_locale => "ru", :available_locale_list => %w[ru]) }
  let!(:level) { create_level(:game => game, :name => "Первый", :text => "Найдите табличку") }

  let(:run) do
    TranslationRun.create!(:game => game, :actor => actor, :model => "claude-opus-5",
                           :state => TranslationRun::PENDING,
                           :target_locale_list => %w[en pl],
                           :fields_total => described_class.plan(game, %w[en pl]).size)
  end

  # A fake standing in for Translation::Client. Records the order calls were
  # made in, which is how the caching structure is asserted.
  class FakeClient
    attr_reader :calls

    def initialize(&behaviour)
      @calls = []
      @behaviour = behaviour
    end

    def translate(unit:, locale:)
      @calls << [ unit.key, locale ]
      @behaviour&.call(unit, locale)

      texts = unit.fields.each_with_object({}) do |missing, acc|
        key = Translation::Unit.field_key(missing.record, missing.field)
        acc[key] = "[#{locale}] #{missing.record[missing.field]}"
      end

      Translation::Client::Result.new(:texts => texts, :input_tokens => 100,
                                      :output_tokens => 50, :cache_read_tokens => 10)
    end
  end

  it "writes one proposal per missing field per locale" do
    described_class.new(run, :client => FakeClient.new).call

    expect(run.reload.state).to eq(TranslationRun::SUCCEEDED)
    expect(run.translation_proposals.count).to eq(run.fields_total)
    expect(run.translation_proposals.pluck(:locale).uniq).to match_array(%w[en pl])
    expect(run.fields_done).to eq(run.fields_total)
  end

  # THE cost-critical assertion. Levels outer, locales inner: the source block
  # stays in place across a unit's locales, so every locale after the first
  # reads the cached prefix. Reverse the loops and every call is a miss.
  it "translates each unit into every locale before moving to the next unit" do
    client = FakeClient.new
    described_class.new(run, :client => client).call

    units = client.calls.map(&:first)
    expect(units).to eq(units.chunk_while { |a, b| a == b }.flat_map { |c| c })
    expect(client.calls.each_slice(2).map { |pair| pair.map(&:last) }.uniq).to eq([ %w[en pl] ])
  end

  it "snapshots the source text and flags each proposal" do
    described_class.new(run, :client => FakeClient.new).call

    proposal = run.translation_proposals.find_by(:field => "text", :locale => "en")
    expect(proposal.source_text).to eq("Найдите табличку")
    expect(proposal.proposed_text).to eq("[en] Найдите табличку")
    expect(proposal.flag_list).to eq([])
  end

  it "accumulates token usage onto the run" do
    described_class.new(run, :client => FakeClient.new).call

    expect(run.reload.cache_read_tokens).to be > 0
    expect(run.input_tokens).to be > 0
  end

  # Resumability. The unique index is the mechanism; this proves it works.
  it "skips fields that already have a proposal when re-entered" do
    described_class.new(run, :client => FakeClient.new).call
    written = run.translation_proposals.count

    run.update!(:state => TranslationRun::RUNNING, :fields_done => 0)
    second = FakeClient.new
    described_class.new(run, :client => second).call

    expect(run.translation_proposals.count).to eq(written)
    expect(second.calls).to be_empty
  end

  it "records a failed unit and carries on to the next one" do
    create_level(:game => game, :name => "Второй", :text => "Идите дальше")
    run.update!(:fields_total => described_class.plan(game, %w[en pl]).size)

    boom = FakeClient.new do |unit, _locale|
      raise Translation::Client::Error, "429" if unit.key.start_with?("Level")
    end
    described_class.new(run, :client => boom).call

    expect(run.reload.fields_failed).to be > 0
    expect(run.state).to eq(TranslationRun::SUCCEEDED)
    expect(run.translation_proposals.where(:translatable_type => "Game")).to be_present
  end

  it "stops when the run is cancelled mid-flight" do
    create_level(:game => game, :name => "Второй", :text => "Идите дальше")
    run.update!(:fields_total => described_class.plan(game, %w[en pl]).size)

    cancelling = FakeClient.new { run.update_column(:state, TranslationRun::CANCELLED) }
    described_class.new(run, :client => cancelling).call

    expect(run.reload.state).to eq(TranslationRun::CANCELLED)
    expect(cancelling.calls.size).to eq(1)
  end

  it "never proposes for the game's primary locale" do
    run.update!(:target_locale_list => %w[ru en])
    described_class.new(run, :client => FakeClient.new).call

    expect(run.translation_proposals.pluck(:locale).uniq).to eq([ "en" ])
  end
end
