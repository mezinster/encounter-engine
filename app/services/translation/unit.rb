# app/services/translation/unit.rb
#
# One cacheable prompt unit: either the game's own header fields, or a whole
# level subtree (the level, its hints, and its questions' options).
#
# The subtree is the unit for two reasons that happen to agree. Quality: game
# content is referential -- a hint says "look at the sign you found", and
# translated in isolation the pronoun has no referent. Cost: this is the
# cheapest shape per unit of translated text, because a per-field call re-sends
# the rules every time and is far too short to reach Claude Opus 5's 512-token
# minimum cacheable prefix, so nothing ever caches at all.
module Translation
  class Unit
    attr_reader :key, :fields

    def self.field_key(record, field)
      "#{record.class.name}##{record.id}.#{field}"
    end

    def self.for_game(game, fields)
      return nil if fields.empty?

      new("Game##{game.id}", fields)
    end

    def self.for_level(level, fields)
      return nil if fields.empty?

      new("Level##{level.id}", fields)
    end

    # A unit whose source text is supplied directly rather than derived from
    # fields. The estimator needs two shapes that correspond to no record set: a
    # baseline carrying almost nothing, and a bulk unit carrying every source at
    # once. Both go through the same Client#request_body as a real call, which
    # is what keeps the estimate describing the run that will actually happen.
    def self.raw(key, text)
      new(key, [], :source => text)
    end

    def initialize(key, fields, source: nil)
      @key    = key
      @fields = fields
      @source = source
    end

    # Every field is labelled with the key the model must echo back, so the
    # response maps to records without positional guessing.
    def source_text
      return @source unless @source.nil?

      @fields.map do |missing|
        "#{self.class.field_key(missing.record, missing.field)}: #{missing.record[missing.field]}"
      end.join("\n\n")
    end
  end
end
