# app/models/concerns/translatable_content.rb
#
# Author-written game content in more than one language.
#
# The model's own column holds the game's PRIMARY language -- exactly the text
# it held before this feature existed. content_translations holds only the
# other languages. That asymmetry is deliberate: it means no existing row was
# rewritten to add multilingual support, and a game that never declares a
# second locale takes no join and no new code path.
#
# Including models must define #translation_game, returning the Game whose
# primary_locale governs them.
module TranslatableContent
  extend ActiveSupport::Concern

  included do
    has_many :content_translations, :as => :translatable, :dependent => :destroy
    after_save :persist_pending_translations
  end

  # Text for `locale`, falling back to the column rather than returning nil.
  #
  # Checks the pending (unsaved) value first: a failed save re-renders the
  # form on the very same instance, and translation_for only sees rows that
  # made it into content_translations, which persist_pending_translations
  # writes after_save -- a save that never got there leaves nothing for it to
  # find. See #pending_translation_for.
  def translated(field, locale)
    pending = pending_translation_for(field, locale)
    return pending if pending

    return self[field] if primary_locale?(locale)

    translation_for(field, locale)&.value.presence || self[field]
  end

  # "Is there usable text for this locale", NOT "does a row exist".
  def translated?(field, locale)
    return self[field].to_s.strip.present? if primary_locale?(locale)

    translation_for(field, locale)&.value.to_s.strip.present?
  end

  # Which of `fields` have no usable text in `locale`.
  def missing_translated_fields(fields, locale)
    Array(fields).reject { |field| self.translated?(field, locale) }
  end

  # Accepts { "en" => { "text" => "...", "name" => "..." }, "ka" => { ... } }.
  # Applied on save so a validation failure does not write half the languages.
  def translations_attributes=(attributes)
    @pending_translations = attributes || {}
  end

  private

  def primary_locale?(locale)
    locale.to_s == self.translation_game&.primary_locale.to_s
  end

  # A failed save re-renders the form, which re-reads translated(...) from the
  # database -- where nothing was written, because persistence happens
  # after_save. Preferring the pending value keeps the author's typing on screen
  # instead of silently discarding it.
  #
  # Deliberately NOT consulted by translated? -- the publish gate (and anything
  # else asking "is this actually translated") must keep answering only for what
  # is persisted, or an author could pass the gate on text that a failed save
  # never wrote to content_translations.
  def pending_translation_for(field, locale)
    return nil if @pending_translations.blank?
    @pending_translations.dig(locale.to_s, field.to_s).presence
  end

  # Searches the loaded association rather than querying, so a controller that
  # preloads with includes(:content_translations) pays one query for the page
  # instead of one per field. See the query-count guard in Task 5.
  def translation_for(field, locale)
    self.content_translations.detect do |translation|
      translation.field == field.to_s && translation.locale == locale.to_s
    end
  end

  def persist_pending_translations
    return if @pending_translations.blank?

    primary = self.translation_game&.primary_locale.to_s
    @pending_translations.each do |locale, fields|
      # The primary language lives in the column; storing it here too would
      # create two sources of truth that quietly diverge.
      next if locale.to_s == primary

      fields.each do |field, value|
        record = ContentTranslation.find_or_initialize_by(
          :translatable => self, :field => field.to_s, :locale => locale.to_s
        )
        record.value = value
        record.save!
      end
    end
    @pending_translations = nil
    self.content_translations.reload
  end
end
