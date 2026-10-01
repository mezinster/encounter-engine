require "rails_helper"

# A field whose `format` is "%{message}" renders its messages with no field
# name. That is only safe if EVERY message the field can produce is a whole
# sentence -- otherwise a stock rails-i18n predicate ("слишком длинный") from a
# future validator would render with no noun at all. See the 2026-10-01
# widgets-and-review spec, §4.4.
describe "full-sentence validation messages" do
  SENTENCE_FIELDS = {
    "answer"     => %w[value],
    "game"       => %w[name description max_team_number starts_at registration_deadline],
    "game_entry" => %w[game team_id],
    "invitation" => %w[for_user recepient_nickname for_user_id],
    "level"      => %w[name text],
    "team"       => %w[name],
    "user"       => %w[email nickname password password_confirmation]
  }.freeze

  SENTENCE_NUMERIC_KEYS = %w[greater_than greater_than_or_equal_to less_than
                    less_than_or_equal_to equal_to other_than odd even].freeze

  def locale_tree(locale)
    YAML.unsafe_load_file(Rails.root.join("config/locales/#{locale}.yml"))[locale]
      .dig("activerecord", "errors", "models")
  end

  # The message keys a validator can raise, and the field they land on.
  def expected_keys(validator, attr)
    custom = validator.options[:message]
    return [[attr, custom.to_s]] if custom.is_a?(Symbol)
    return [] if custom.is_a?(String) # literal: checked separately below

    case validator.kind
    when :presence     then [[attr, "blank"]]
    when :uniqueness   then [[attr, "taken"]]
    when :format       then [[attr, "invalid"]]
    when :inclusion    then [[attr, "inclusion"]]
    when :confirmation then [["#{attr}_confirmation", "confirmation"]]
    when :length
      o = validator.options
      keys = []
      keys << "too_short"    if o[:minimum] || o[:in] || o[:within]
      keys << "too_long"     if o[:maximum] || o[:in] || o[:within]
      keys << "wrong_length" if o[:is]
      keys.map { |k| [attr, k] }
    when :numericality
      keys = ["not_a_number"] + (validator.options.keys.map(&:to_s) & SENTENCE_NUMERIC_KEYS)
      keys << "not_an_integer" if validator.options[:only_integer]
      keys.map { |k| [attr, k] }
    else
      [[attr, "(unmapped validator kind: #{validator.kind})"]]
    end
  end

  %w[ru en].each do |locale|
    context "in #{locale}.yml" do
      let(:models) { locale_tree(locale) }

      it "gives exactly the audited fields a bare-message format" do
        bare = models.flat_map do |model, h|
          (h["attributes"] || {}).select { |_, msgs| msgs.is_a?(Hash) && msgs["format"] == "%{message}" }
                                 .keys.map { |attr| "#{model}.#{attr}" }
        end
        expected = SENTENCE_FIELDS.flat_map { |m, attrs| attrs.map { |a| "#{m}.#{a}" } }
        expect(bare).to match_array(expected)
      end

      it "writes every message of those fields as a sentence" do
        lowercase = SENTENCE_FIELDS.flat_map do |model, attrs|
          attrs.flat_map do |attr|
            (models.dig(model, "attributes", attr) || {}).except("format")
              .reject { |_, text| text.to_s.match?(/\A\p{Lu}/) }
              .map { |key, text| "#{model}.#{attr}.#{key}: #{text}" }
          end
        end
        expect(lowercase).to eq([]), "not a sentence:\n#{lowercase.join("\n")}"
      end

      it "has a sentence for every message a validator on those fields can raise" do
        missing = SENTENCE_FIELDS.flat_map do |model, attrs|
          klass = model.camelize.constantize
          attrs.flat_map do |attr|
            klass.validators_on(attr.to_sym).flat_map do |validator|
              literal = validator.options[:message]
              if literal.is_a?(String)
                literal.match?(/\A\p{Lu}/) ? [] : ["#{model}.#{attr}: literal message #{literal.inspect}"]
              else
                expected_keys(validator, attr).reject { |field, key| models.dig(model, "attributes", field, key) }
                                              .map { |field, key| "#{model}.#{field}.#{key} (#{validator.kind})" }
              end
            end
          end
        end
        expect(missing).to eq([]), "missing sentence message:\n#{missing.join("\n")}"
      end
    end
  end
end
