# app/services/translation/client.rb
#
# The ONLY place in this application that touches the Anthropic SDK. Every spec
# in the feature stubs this seam, so no spec needs a network or a key.
module Translation
  class Client
    Error = Class.new(StandardError)

    # cache_write_tokens is not decoration beside cache_read_tokens: it is the
    # only way to see caching FAILING. input_tokens reports the uncached
    # remainder alone, so a call that wrote 4,000 tokens at 1.25x and a call
    # that cached nothing both report a tiny input and a zero read.
    Result = Struct.new(:texts, :input_tokens, :output_tokens, :cache_read_tokens,
                        :cache_write_tokens, :keyword_init => true)

    # An array of {key, text} rather than an object with dynamic property
    # names: JSON Schema cannot express "one property per field", and a fixed
    # schema is what lets strict validation happen at the tool-call layer --
    # so a malformed response is retried by the API, not by a parse-failure
    # loop here that would burn a second full call.
    RESPONSE_SCHEMA = {
      "type" => "object",
      "properties" => {
        "translations" => {
          "type"  => "array",
          "items" => {
            "type" => "object",
            "properties" => {
              "key"  => { "type" => "string" },
              "text" => { "type" => "string" }
            },
            "required" => [ "key", "text" ],
            "additionalProperties" => false
          }
        }
      },
      "required" => [ "translations" ],
      "additionalProperties" => false
    }.freeze

    # The rule that matters most is about codes, not language. Answer is not a
    # translatable model, so answers are never sent -- but a level's text or a
    # hint can QUOTE a code the player must type, and translating one silently
    # breaks the game for every team.
    RULES = <<~PROMPT.freeze
      You translate content for an urban puzzle game. Each input line is
      "KEY: TEXT". Return one entry per key, translating only TEXT.

      Rules:
      - Copy verbatim, never translate: digit sequences, codes, coordinates,
        times, house numbers, URLs, and Latin-script proper nouns. A player
        types these exactly as printed; a translated code breaks the game.
      - Preserve line breaks and paragraph structure exactly.
      - Keep the register of the original. This is read under time pressure.
      - Translate every key you are given, and invent no keys.
    PROMPT

    def self.configured?
      ENV["ANTHROPIC_API_KEY"].present?
    end

    # cache: whether to place a cache breakpoint on the source block. True is
    # right whenever the same prefix will be sent more than once -- which is
    # what a multi-locale run does, and the whole reason the runner loops units
    # outer. With ONE target locale each prefix is sent exactly once, the write
    # premium can never be amortised, and the marker is a straight surcharge.
    def initialize(api_key:, model:, cache: true)
      @api_key = api_key
      @model   = model
      @cache   = cache
    end

    def translate(unit:, locale:)
      response = messages.create(**request_body(unit, locale))

      # Before content, always.
      raise Error, "model refused: #{response.stop_reason}" if response.stop_reason == :refusal

      build_result(response)
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "#{e.class}: #{e.message}"
    end

    # The pre-flight. Free, exact, and -- crucially -- built from the SAME
    # request body #translate will send, so the figure on the confirmation
    # screen prices the run that actually happens rather than a second,
    # hand-rolled approximation of it. Kept behind this seam like everything
    # else that touches the SDK, so no spec needs a network or a key.
    def count_input_tokens(unit:, locale:)
      response = messages.count_tokens(**request_body(unit, locale).except(:max_tokens))
      response.input_tokens.to_i
    rescue StandardError => e
      raise Error, "#{e.class}: #{e.message}"
    end

    private

    # One body, two callers. If the two ever diverge the estimate silently
    # stops describing the run, and nothing would fail to say so.
    def request_body(unit, locale)
      {
        :model      => @model,
        :max_tokens => 8_000,
        :output_config => {
          # The single largest cost lever after model choice. NOT
          # thinking: {type: "disabled"} -- on Claude Opus 5 that has a
          # documented tendency to leak <thinking> tags into the visible
          # response, which here would land verbatim inside a game level.
          :effort => "low",
          :format => { :type => "json_schema", :schema => RESPONSE_SCHEMA }
        },
        :system_ => [
          { :type => "text", :text => RULES },
          source_block(unit)
        ],
        :messages => [
          { :role => "user", :content => "Translate the above into #{language_name(locale)}." }
        ]
      }
    end

    # The breakpoint, when there is one. Everything up to and including this
    # block is identical across every target locale for this unit, so the first
    # locale writes the cache at 1.25x and the rest read it at 0.1x -- and the
    # marker has to sit on the LAST stable block, with the varying instruction
    # after it in :messages, or the prefix match never holds.
    def source_block(unit)
      block = { :type => "text", :text => unit.source_text }
      return block unless @cache

      block.merge(:cache_control => { :type => "ephemeral" })
    end

    def messages
      @messages ||= ::Anthropic::Client.new(:api_key => @api_key).messages
    end

    # The language's own name, which is what the locale switcher already shows.
    def language_name(locale)
      I18n.t("locales.#{locale}", :locale => locale)
    end

    def build_result(response)
      block = response.content.find { |b| b.type == :text }
      raise Error, "no text block in response" if block.nil?

      payload = JSON.parse(block.text)
      texts   = payload.fetch("translations", []).each_with_object({}) do |entry, acc|
        acc[entry["key"]] = entry["text"]
      end

      usage = response.usage
      Result.new(
        :texts             => texts,
        :input_tokens       => usage&.input_tokens.to_i,
        :output_tokens      => usage&.output_tokens.to_i,
        :cache_read_tokens  => usage&.cache_read_input_tokens.to_i,
        :cache_write_tokens => usage&.cache_creation_input_tokens.to_i
      )
    end
  end
end
