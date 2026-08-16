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

  # THE overwrite bug. A unit's fields are the UNION across the run's locales
  # -- that is what makes the cached prefix identical for every locale of a
  # unit, and it must stay that way -- so a run targeting en+pl on a game whose
  # English is half done used to propose a re-translation of the finished
  # English fields too. Accepting one goes through find_or_initialize_by +
  # record.value =, which OVERWRITES the human's row with no history, and a
  # re-translation of already-good text trips none of the five flags, so
  # accept_all swept it up silently.
  describe "a locale that is already partly translated" do
    # One object, deliberately: translations_attributes= stashes the values on
    # the instance and persist_pending_translations writes them after_save, so
    # assigning to `game.levels.first` and saving `game.levels.first` -- two
    # separate queries, two separate objects -- persists nothing at all.
    let(:half_done) do
      level.translations_attributes = { "en" => { "name" => "Typed by a human" } }
      level.save!
      expect(level.reload.translated("name", "en")).to eq("Typed by a human")
      game
    end

    let(:mixed_run) do
      half_done
      TranslationRun.create!(:game => game, :actor => actor, :model => "claude-opus-5",
                             :state => TranslationRun::PENDING,
                             :target_locale_list => %w[en pl],
                             :fields_total => described_class.plan(game, %w[en pl]).size)
    end

    it "writes no proposal for a field that locale already has" do
      described_class.new(mixed_run, :client => FakeClient.new).call

      expect(
        mixed_run.translation_proposals.exists?(:translatable_type => "Level",
                                                :translatable_id   => level.id,
                                                :field => "name", :locale => "en")
      ).to eq(false)
    end

    it "still writes one for the same field in the locale that lacks it" do
      described_class.new(mixed_run, :client => FakeClient.new).call

      expect(
        mixed_run.translation_proposals.exists?(:translatable_type => "Level",
                                                :translatable_id   => level.id,
                                                :field => "name", :locale => "pl")
      ).to eq(true)
    end

    it "leaves the human's translation exactly as typed" do
      described_class.new(mixed_run, :client => FakeClient.new).call

      expect(level.reload.translated("name", "en")).to eq("Typed by a human")
    end

    # The secondary symptom that confirms the bug from the other side.
    # fields_total comes from Runner.plan, which IS per-locale, so a run that
    # proposed over finished work reported "6 of 4".
    it "never reports more fields done than the plan said existed" do
      described_class.new(mixed_run, :client => FakeClient.new).call

      expect(mixed_run.reload.fields_done).to be <= mixed_run.fields_total
      expect(mixed_run.fields_done + mixed_run.fields_failed).to eq(mixed_run.fields_total)
    end

    # The unit still carries the union -- the cost model depends on it. If this
    # ever fails, the fix went in at the wrong layer.
    it "still sends the whole unit as one cacheable prompt" do
      client = FakeClient.new
      described_class.new(mixed_run, :client => client).call

      level_unit = client.calls.map(&:first).find { |k| k.start_with?("Level") }
      expect(level_unit).to be_present
      expect(client.calls.count { |k, _| k == level_unit }).to eq(2)
    end
  end

  # sweep_stale! fails any active run whose updated_at is older than 15
  # minutes, and nothing in the runner used to advance it: increment! goes
  # through update_counters(touch: nil) and the failure path uses
  # update_column. The existing sweep spec sets updated_at by hand, which is
  # exactly why this was invisible -- it proved the sweep works, never that a
  # healthy run stays out of its way.
  it "advances updated_at as it works, so a sweep mid-run cannot fail it" do
    create_level(:game => game, :name => "Второй", :text => "Идите дальше")
    run.update!(:fields_total => described_class.plan(game, %w[en pl]).size)

    # The real shape of the failure, not a hand-set timestamp: the clock moves
    # while the thread calls the API, and a sweep fires between calls -- which
    # it does on every reload of the operator's own progress page. Ten minutes
    # per call is conservative; the design's 400-field cap is ~84 sequential
    # calls, so passing fifteen minutes is ordinary, not an edge case.
    swept  = []
    client = FakeClient.new do
      travel 10.minutes
      swept << TranslationRun.sweep_stale!
    end
    described_class.new(run, :client => client).call

    # Every sweep saw a run that had made progress since it last looked.
    # Without the per-unit touch, updated_at stayed at the stamp `call` wrote
    # when it set RUNNING, and the second sweep failed a perfectly healthy run.
    expect(swept.size).to be > 1
    expect(swept).to all(eq(0))
    expect(run.reload.state).to eq(TranslationRun::SUCCEEDED)
  end

  # Blank output is a flag, not a crash. TranslationProposal used to validate
  # proposed_text's presence, so create! raised RecordInvalid -- not a
  # Client::Error, so it slipped past translate's rescue into call's
  # `rescue StandardError` and failed the WHOLE run, abandoning every
  # remaining unit and rolling back that unit's transaction. Hint#text has no
  # presence validation, so a blank source is reachable and the failure
  # repeated on every retry.
  it "flags blank output as empty instead of failing the run" do
    blank = Class.new(FakeClient) do
      define_method(:translate) do |unit:, locale:|
        result = super(:unit => unit, :locale => locale)
        result.texts.each_key { |k| result.texts[k] = "" if k.include?(".name") }
        result
      end
    end.new

    described_class.new(run, :client => blank).call

    expect(run.reload.state).to eq(TranslationRun::SUCCEEDED)
    empties = run.translation_proposals.select { |p| p.flag_list.include?("empty") }
    expect(empties).not_to be_empty
    expect(empties.map(&:proposed_text).uniq).to eq([ "" ])
  end

  # Resumability, driven the way Retry drives it: a failed run, re-entered,
  # translates only what has no proposal and ends SUCCEEDED. Before the Retry
  # route existed nothing ever called this a second time, so the mechanism was
  # built and unreachable.
  it "translates only the outstanding fields when a failed run is retried" do
    create_level(:game => game, :name => "Второй", :text => "Идите дальше")
    run.update!(:fields_total => described_class.plan(game, %w[en pl]).size)

    boom = FakeClient.new do |unit, _locale|
      raise Translation::Client::Error, "429" if unit.key.start_with?("Level")
    end
    described_class.new(run, :client => boom).call
    already = run.reload.translation_proposals.count
    expect(already).to be > 0
    expect(run.fields_failed).to be > 0

    second = FakeClient.new
    described_class.new(run, :client => second).call

    expect(run.reload.state).to eq(TranslationRun::SUCCEEDED)
    expect(run.fields_failed).to eq(0)
    expect(run.translation_proposals.count).to eq(run.fields_total)
    # Only the game header was done first time, so the second pass must have
    # skipped it and called only for the levels.
    expect(second.calls.map(&:first)).not_to include("Game##{game.id}")
  end

  # Re-entry is explicit, not incidental: call sets RUNNING every time, and it
  # used to overwrite started_at with it -- erasing how long the work had
  # really been going, the one number an operator reads when deciding whether
  # a run is wedged.
  it "keeps the first pass's started_at and clears finished_at on re-entry" do
    described_class.new(run, :client => FakeClient.new).call
    first_started = run.reload.started_at
    expect(run.finished_at).to be_present

    run.update!(:state => TranslationRun::FAILED)
    described_class.new(run, :client => FakeClient.new).call

    expect(run.reload.started_at.to_i).to eq(first_started.to_i)
  end
end
