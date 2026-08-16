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
module Translation
  class Runner
    def self.plan(game, locales)
      locales.reject { |l| l.to_s == game.primary_locale.to_s }
             .flat_map { |locale| game.missing_translated_fields_in(locale) }
    end

    def initialize(run, client: nil)
      @run    = run
      @client = client
    end

    def call
      @run.update!(:state => TranslationRun::RUNNING, :started_at => Time.now)

      units.each do |unit|
        locales.each do |locale|
          return finish(TranslationRun::CANCELLED) if cancelled?

          translate(unit, locale)
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

    # Grouped by unit, and the game header first so a run that dies early has
    # still produced the game's own name and description.
    def units
      game   = @run.game
      fields = locales.flat_map { |locale| game.missing_translated_fields_in(locale) }
      by_locale_agnostic = fields.uniq { |f| [ f.record.class.name, f.record.id, f.field ] }

      header = Unit.for_game(game, by_locale_agnostic.select { |f| f.record == game })
      levels = game.levels.map do |level|
        Unit.for_level(level, by_locale_agnostic.select { |f| owning_level(f.record) == level.id })
      end

      ([ header ] + levels).compact
    end

    def owning_level(record)
      case record
      when Level    then record.id
      when Hint     then record.level_id
      when Question then record.level_id
      when Option   then record.question&.level_id
      end
    end

    def cancelled?
      @run.class.where(:id => @run.id).pick(:state) == TranslationRun::CANCELLED
    end

    def translate(unit, locale)
      outstanding = unit.fields.reject { |f| already_proposed?(f, locale) }
      return if outstanding.empty?

      result = client.translate(:unit => unit, :locale => locale)
      record_proposals(outstanding, locale, result)
    rescue Client::Error => e
      # Per unit, never per run. A field that failed simply has no proposal
      # row, so the resumability rule re-runs exactly the failed fields.
      @run.increment!(:fields_failed, outstanding.size)
      @run.update_column(:error_message, e.message)
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
          next if text.nil?

          source = missing.record[missing.field].to_s
          TranslationProposal.create!(
            :translation_run => @run,
            :translatable    => missing.record,
            :field           => missing.field,
            :locale          => locale,
            :source_text     => source,
            :proposed_text   => text,
            :flags           => Flags.for(:source => source, :proposed => text).join(","),
            :state           => TranslationProposal::PENDING
          )
          @run.increment!(:fields_done)
        end

        @run.increment!(:input_tokens,      result.input_tokens)
        @run.increment!(:output_tokens,     result.output_tokens)
        @run.increment!(:cache_read_tokens, result.cache_read_tokens)
      end
    end

    def finish(state)
      @run.update!(:state => state, :finished_at => Time.now)
    end

    def client
      @client ||= Client.new(:api_key => ENV["ANTHROPIC_API_KEY"], :model => @run.model)
    end
  end
end
