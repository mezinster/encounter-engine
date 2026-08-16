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

    # Contiguity IS the property. A unit's calls must not be interrupted by
    # another unit's, because the cached prefix is that unit's source text --
    # once another unit's prompt has replaced it, coming back costs full price.
    # chunk collapses only CONSECUTIVE runs, so a unit reappearing later
    # survives into the result and breaks this equality.
    expect(units.chunk { |u| u }.map(&:first)).to eq(units.uniq)

    # ...and each unit sees every target locale, in order. Expressed against the
    # run's own locale list rather than a literal slice width, so adding a third
    # target locale cannot silently misalign this.
    per_unit = client.calls.group_by(&:first).values.map { |calls| calls.map(&:last) }
    expect(per_unit.uniq).to eq([ run.target_locale_list ])
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

    # Write through a SEPARATE row/instance, not run.update_column -- update_column
    # also writes the in-memory attribute on `run`, which would let a naive
    # `@run.state == CANCELLED` check pass this example for the wrong reason.
    cancelling = FakeClient.new do
      TranslationRun.where(:id => run.id).update_all(:state => TranslationRun::CANCELLED)
    end
    described_class.new(run, :client => cancelling).call

    expect(run.reload.state).to eq(TranslationRun::CANCELLED)
    expect(cancelling.calls.size).to eq(1)
  end

  it "clears the previous pass's failure count and message on a clean retry" do
    create_level(:game => game, :name => "Второй", :text => "Идите дальше")
    run.update!(:fields_total => described_class.plan(game, %w[en pl]).size)

    boom = FakeClient.new do |unit, _locale|
      raise Translation::Client::Error, "429" if unit.key.start_with?("Level")
    end
    described_class.new(run, :client => boom).call
    expect(run.reload.fields_failed).to be > 0
    expect(run.error_message).to be_present

    run.update!(:state => TranslationRun::RUNNING)
    described_class.new(run, :client => FakeClient.new).call

    expect(run.reload.fields_failed).to eq(0)
    expect(run.error_message).to be_nil
    expect(run.fields_done).to eq(run.fields_total)
  end

  # A model that silently omits a field must not vanish from the accounting.
  # Without this, the run ends SUCCEEDED with fields_done + fields_failed
  # short of fields_total and zero failures shown -- "47 of 50", with nothing
  # anywhere naming the three.
  it "counts a field the model omitted as failed rather than losing it" do
    omitted_key = Translation::Unit.field_key(game, "description")

    # Drop one key from whatever FakeClient would otherwise return -- but
    # only for one locale, so exactly one (record, field, locale) triple is
    # missing rather than one per locale.
    partial = Class.new(FakeClient) do
      define_method(:translate) do |unit:, locale:|
        result = super(:unit => unit, :locale => locale)
        result.texts.delete(omitted_key) if locale == "en"
        result
      end
    end.new

    described_class.new(run, :client => partial).call

    expect(run.reload.fields_failed).to eq(1)
    # The invariant that makes a run's self-report trustworthy: every field is
    # accounted for exactly once, either done or failed, never neither.
    expect(run.fields_done + run.fields_failed).to eq(run.fields_total)
    expect(run.translation_proposals.count).to eq(run.fields_total - 1)
    # No proposal row for the omitted field -- that is what lets the
    # resumability rule retry exactly it on a later pass.
    expect(
      run.translation_proposals.exists?(:translatable_type => "Game",
                                        :field => "description", :locale => "en")
    ).to eq(false)
  end

  it "never proposes for the game's primary locale" do
    run.update!(:target_locale_list => %w[ru en])
    described_class.new(run, :client => FakeClient.new).call

    expect(run.translation_proposals.pluck(:locale).uniq).to eq([ "en" ])
  end
end
