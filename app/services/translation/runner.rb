# app/services/translation/runner.rb
#
# Walks a game's missing translatable fields and turns them into proposals.
#
# The loop order is the single cost-critical decision in this feature: UNITS
# OUTER, LOCALES INNER. Prompt caching is a strict prefix match, and the prompt
# is [rules][this unit's source][translate into X]. Holding the unit still
# while the locales vary means every locale after the first reads a cached
# prefix at a tenth of the price. Reverse the loops and, by the time the first
# unit comes round again, the prefix has been replaced once per unit -- every
# single call is a cache miss.
#
# The locale calls must also stay SEQUENTIAL: a cache entry only becomes
# readable once the first response begins streaming, so firing a unit's locales
# concurrently means all of them pay full price. Nothing is waiting on this
# work, so sequential costs nothing.
#
# All of which assumes there IS a second locale. With one, each prefix is sent
# exactly once, the 1.25x write is never amortised, and the breakpoint becomes
# a ~25% surcharge on input -- which is what every run in production did before
# #client started switching it off (see there).
module Translation
  class Runner
    def self.plan(game, locales)
      locales.reject { |l| l.to_s == game.primary_locale.to_s }
             .flat_map { |locale| game.missing_translated_fields_in(locale) }
    end

    # What is genuinely untranslated, PER LOCALE. The union of these is what a
    # unit carries (see #units); the per-locale sets are what keeps the runner
    # from proposing over a locale that is already done -- see #translate.
    def self.missing_fields_by_locale(game, locales)
      locales.each_with_object({}) do |locale, acc|
        acc[locale] = game.missing_translated_fields_in(locale)
      end
    end

    # Public so the controller's pre-flight can price the same units the run
    # will actually send, rather than a second, hand-built approximation of
    # them. An estimate computed off a different work-list is worse than none.
    def self.units_for(game, locales)
      units_from(game, missing_fields_by_locale(game, locales))
    end

    def self.units_from(game, missing_by_locale)
      union = missing_by_locale.values.flatten.uniq { |f| triple(f) }

      header = Unit.for_game(game, union.select { |f| f.record == game })
      levels = game.levels.map do |level|
        Unit.for_level(level, union.select { |f| owning_level(f.record) == level.id })
      end

      ([ header ] + levels).compact
    end

    def self.triple(missing)
      [ missing.record.class.name, missing.record.id, missing.field ]
    end

    def self.owning_level(record)
      case record
      when Level    then record.id
      when Hint     then record.level_id
      when Question then record.level_id
      when Option   then record.question&.level_id
      end
    end

    # One character, not none: the Anthropic API rejects an empty text block and
    # the unit source IS a text block. Costs roughly one token per baseline
    # call, which is noise against a five-figure estimate.
    BASELINE_SOURCE = ".".freeze

    # How much source text goes into one bulk count_tokens call. Well under any
    # model's input limit, and the only thing it bounds is the SIZE of a
    # pre-flight call -- never how many of them there are per unit, which is the
    # property this whole rewrite exists to hold.
    BULK_SOURCE_CHARS = 200_000

    # A pre-flight whose cost does not grow with the game.
    #
    # Every call this run will make is [RULES][unit source][instruction] (see
    # Client#request_body), so a call's input is CONST + tokens(source) +
    # tokens(instruction for that locale), and the job total is:
    #
    #   n_units x SUM_locales baseline(locale) + n_locales x SUM_units tokens(source)
    #
    # Both terms are measurable in a constant number of calls: one baseline per
    # locale -- a unit carrying only BASELINE_SOURCE, so the result is CONST
    # plus that locale's instruction -- and one bulk call carrying every source
    # at once, minus that baseline.
    #
    # This WAS one count_tokens per unit per locale, run synchronously inside
    # the POST that renders the confirmation screen: 71 round trips for a
    # 70-level quiz at one language and ~426 at six. It was never actually
    # reached only because the 400-field cap refused such games before the
    # confirmation screen was ever built -- so this had to be fixed before that
    # cap could move.
    #
    # Approximate in two known ways, both far below the estimate's existing
    # variance against real spend (prompt caching means billed input is a
    # fraction of this figure): the baseline carries one character rather than
    # none, and concatenating sources tokenises a few tokens differently at each
    # boundary.
    def self.estimate_input_tokens(game, locales, client: nil)
      effective = locales.reject { |l| l.to_s == game.primary_locale.to_s }
      return 0 if effective.empty?

      units = units_for(game, effective)
      return 0 if units.empty?

      # Same breakpoint decision the run itself will make (see #client), so the
      # estimate keeps pricing the body that will actually be sent.
      client ||= Client.new(:api_key => ENV["ANTHROPIC_API_KEY"],
                            :model   => Setting.enum("translation_model"),
                            :cache   => effective.size > 1)

      baselines = effective.map do |locale|
        client.count_input_tokens(:unit   => Unit.raw("estimate:baseline", BASELINE_SOURCE),
                                  :locale => locale)
      end

      sources = source_tokens(units, effective.first, baselines.first, client)

      units.size * baselines.sum + effective.size * sources
    end

    # Sum of tokens across every unit's source, measured in as few calls as the
    # size limit allows. Each piece's own baseline is subtracted, because every
    # call carries the rules prefix and the instruction whether it is measuring
    # one unit or a hundred.
    def self.source_tokens(units, locale, baseline, client)
      bulk_groups(units).sum do |group|
        text = group.map(&:source_text).join("\n\n")
        client.count_input_tokens(:unit   => Unit.raw("estimate:bulk", text),
                                  :locale => locale) - baseline
      end
    end

    # Greedy packing. A unit whose own source exceeds the limit still gets a
    # group to itself rather than being dropped or split mid-text: an over-long
    # single prompt is the API's problem to report, and silently omitting a
    # level from the estimate would be worse than an estimate that failed.
    def self.bulk_groups(units)
      groups = []
      size   = 0

      units.each do |unit|
        length = unit.source_text.length
        if groups.empty? || (groups.last.any? && size + length > BULK_SOURCE_CHARS)
          groups << []
          size = 0
        end
        groups.last << unit
        size += length
      end

      groups
    end

    def initialize(run, client: nil)
      @run    = run
      @client = client
    end

    def call
      @run.update!(:state => TranslationRun::RUNNING,
                   # The FIRST pass's start, kept. Re-entry (Retry) is a second
                   # pass over the same run, not a new run, and overwriting
                   # started_at would erase how long the work has really been
                   # going -- which is the one number an operator looks at when
                   # deciding whether a run is wedged.
                   :started_at => @run.started_at || Time.now,
                   # Cleared, because the run is active again. A failed run
                   # carries a finished_at; leaving it would make the run page
                   # claim the run ended while the thread is still calling.
                   :finished_at => nil,
                   # Both describe THIS pass. A re-entered run that succeeds
                   # must not keep reporting the previous pass's failures.
                   :fields_failed => 0, :error_message => nil)

      units.each do |unit|
        locales.each do |locale|
          return finish(TranslationRun::CANCELLED) if cancelled?

          translate(unit, locale)
          # Progress has to advance the CLOCK, not only the counters.
          # TranslationRun.sweep_stale! fails any active run whose updated_at is
          # older than 15 minutes, and neither of the counter paths touches it:
          # increment! goes through update_counters(touch: nil) and the failure
          # path uses update_column, which skips timestamps by definition. So a
          # healthy run was stamped once at RUNNING and then sat still while the
          # thread worked -- and at the design's own 400-field cap a 20-level
          # game into 4 locales is ~84 sequential calls, comfortably past the
          # threshold. Once per unit-locale, i.e. once per API call.
          @run.touch
        end
      end

      finish(TranslationRun::SUCCEEDED)
    rescue StandardError => e
      @run.update!(:state => TranslationRun::FAILED, :error_message => e.message,
                   :finished_at => Time.now)
    end

    private

    def locales
      @locales ||= @run.target_locale_list.reject { |l| l == @run.game.primary_locale.to_s }
    end

    # Computed once, at the top of the pass, and memoised: the run writes
    # proposals rather than translations, so nothing it does can change what is
    # missing underneath it.
    def missing_by_locale
      @missing_by_locale ||= self.class.missing_fields_by_locale(@run.game, locales)
    end

    # The per-locale triples, as sets, for the filter in #translate.
    def missing_triples
      @missing_triples ||= missing_by_locale.transform_values { |fields|
        fields.map { |f| self.class.triple(f) }.to_set
      }
    end

    # Grouped by unit, and the game header first so a run that dies early has
    # still produced the game's own name and description.
    #
    # A unit's fields are the UNION across the run's locales, deliberately.
    # That union is what makes the cached prefix byte-identical for every
    # locale of a unit, which is the entire cost model (see the header
    # comment). Narrowing it per locale would break that; the narrowing
    # happens at the point of use instead, in #translate.
    def units
      @units ||= self.class.units_from(@run.game, missing_by_locale)
    end

    def cancelled?
      @run.class.where(:id => @run.id).pick(:state) == TranslationRun::CANCELLED
    end

    def translate(unit, locale)
      # TWO filters, and they answer different questions. already_proposed?
      # asks "did THIS run already do it" -- resumability. missing_in? asks
      # "is it actually untranslated in THIS locale" -- and without it a run
      # targeting en+pl where en is half done proposes a re-translation of
      # every already-translated English field. Accepting one goes through
      # find_or_initialize_by + record.value =, which OVERWRITES the human's
      # row with no history; and a re-translation of already-good text trips
      # none of the five flags, so accept_all sweeps it up silently. The
      # design says so twice: "Existing translations: never touched",
      # "v1 fills gaps only".
      outstanding = unit.fields.select { |f| missing_in?(f, locale) }
                               .reject { |f| already_proposed?(f, locale) }
      return if outstanding.empty?

      result = client.translate(:unit => unit, :locale => locale)
      record_proposals(outstanding, locale, result)
    rescue Client::Error => e
      # Per unit, never per run. A field that failed simply has no proposal
      # row, so the resumability rule re-runs exactly the failed fields.
      @run.increment!(:fields_failed, outstanding.size)
      @run.update_column(:error_message, e.message)
    end

    def missing_in?(missing, locale)
      missing_triples.fetch(locale, Set.new).include?(self.class.triple(missing))
    end

    def already_proposed?(missing, locale)
      @run.translation_proposals.exists?(
        :translatable_type => missing.record.class.name,
        :translatable_id   => missing.record.id,
        :field             => missing.field,
        :locale            => locale
      )
    end

    def record_proposals(outstanding, locale, result)
      TranslationProposal.transaction do
        outstanding.each do |missing|
          text = result.texts[Unit.field_key(missing.record, missing.field)]
          if text.nil?
            # The model omitted this field. Counted as failed rather than
            # skipped: with no proposal row it will be retried by the
            # resumability rule, and a run must not report success over
            # fields it never actually produced.
            @run.increment!(:fields_failed)
            next
          end

          source = missing.record[missing.field].to_s
          TranslationProposal.create!(
            :translation_run => @run,
            :translatable    => missing.record,
            :field           => missing.field,
            :locale          => locale,
            :source_text     => source,
            :proposed_text   => text,
            # source_locale, not `locale`: the flags judge the SOURCE, and
            # `identical` in particular asks whether the game's own language
            # survived into the proposal.
            :flags           => Flags.for(:source        => source,
                                          :proposed      => text,
                                          :source_locale => @run.game.primary_locale).join(","),
            :state           => TranslationProposal::PENDING
          )
          @run.increment!(:fields_done)
        end

        @run.increment!(:input_tokens,       result.input_tokens)
        @run.increment!(:output_tokens,      result.output_tokens)
        @run.increment!(:cache_read_tokens,  result.cache_read_tokens)
        # The write, beside the read. A read with no write beside it is a
        # cross-run cache hit; a write with no read is money spent for nothing.
        # Only the pair distinguishes them.
        @run.increment!(:cache_write_tokens, result.cache_write_tokens)
      end
    end

    def finish(state)
      @run.update!(:state => state, :finished_at => Time.now)
    end

    # A breakpoint is worth its 1.25x write only if something reads it. Each
    # unit's prefix is sent once per locale, so a run with one effective locale
    # sends every prefix exactly once and every write is dead weight -- which
    # is what all four production runs did before this guard existed.
    #
    # Run-level, not per-unit. A multi-locale run can still contain a unit that
    # only one locale is missing (see #translate's `outstanding` filter), and
    # that unit's write goes unread. Modelling that would mean deciding per
    # call rather than per client, for a case worth a rounding error.
    def client
      @client ||= Client.new(:api_key => ENV["ANTHROPIC_API_KEY"], :model => @run.model,
                             :cache   => locales.size > 1)
    end
  end
end
