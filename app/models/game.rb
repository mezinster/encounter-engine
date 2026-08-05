# -*- encoding : utf-8 -*-
class Game < ApplicationRecord
  include TranslatableContent

  TRANSLATABLE_FIELDS = %w[name description].freeze

  # Not a boolean: these entries are simultaneously the publish gate's reason
  # for refusing and the author's to-do list, so they carry enough to render a
  # deep link straight to the offending field.
  MissingTranslation = Struct.new(:record, :field, :locale, :label)

  def translation_game
    self
  end

  belongs_to :author, class_name: "User", optional: true
  has_many :levels, -> {  order('position') }
  has_many :logs, -> { order('time') }
  has_many :game_entries, :class_name => "GameEntry"
  has_many :game_passings, :class_name => "GamePassing"

  validates :name, presence: true, uniqueness: true
  validates :description, presence: true
  validates :max_team_number, numericality: { greater_than: 0, less_than: 10000 }
  validates :author, presence: true

  validate :game_starts_in_the_future
  validate :valid_max_num

  validate :deadline_is_in_future
  validate :deadline_is_before_game_start

  scope :by, ->(author) { where(author_id: author) }
  scope :non_drafts, -> { where(is_draft: false) }
  scope :finished, -> { where.not(author_finished_at: nil) }

  def self.started
    Game.all.select(&:started?)
  end

  def draft?
    self.is_draft
  end

  def started?
    self.starts_at.nil? ? false : Time.now > self.starts_at
  end

  def editing_locked?
    self.editing_locked_at.present?
  end

  def withdrawn?
    self.withdrawn_at.present?
  end

  def created_by?(user)
    user.author_of?(self)
  end

  def finished_teams
    GamePassing.of_game(self).finished.map(&:team)
  end

  def place_of(team)
    game_passing = GamePassing.of(team, self)
    return nil unless game_passing and game_passing.finished?

    count_of_finished_before = GamePassing.of_game(self).finished_before(game_passing.finished_at).count
    count_of_finished_before + 1
  end

  def self.notstarted
    Game.all.select { |game| !game.draft? && !game.started? }
  end

  def free_place_of_team!
    if self.requested_teams_number>0
      self.requested_teams_number-=1
      self.save
    end
  end

  def reserve_place_for_team!
    self.requested_teams_number+=1;
    self.save
  end

  def can_request?
    self.requested_teams_number < self.max_team_number
    Game.all.select {|game| !game.started?}
  end

  def finish_game!
    self.author_finished_at = Time.now
    self.save!
  end

  def author_finished?
    !self.author_finished_at.nil?
  end

  def is_testing?
    self.is_testing
  end

  # Stored comma-separated rather than serialised: it is a short list of ASCII
  # locale codes, it has to be readable in a SQLite console during an incident,
  # and a plain string needs no coder on either database.
  def available_locale_list
    self.available_locales.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def available_locale_list=(list)
    self.available_locales = Array(list).map(&:to_s).map(&:strip).reject(&:blank?).join(",")
  end

  def multilingual?
    self.available_locale_list.size > 1
  end

  def missing_translations
    non_primary = self.available_locale_list - [self.primary_locale.to_s]
    return [] if non_primary.empty?

    non_primary.flat_map do |locale|
      translatable_records.flat_map do |record|
        record.class::TRANSLATABLE_FIELDS.map do |field|
          next if record.translated?(field, locale)

          MissingTranslation.new(record, field, locale, label_for(record, field))
        end.compact
      end
    end
  end

  def translations_complete?
    self.missing_translations.empty?
  end

  validate :available_locales_are_known
  validate :available_locales_include_primary
  validate :primary_locale_is_settled
  validate :declared_locales_are_translated_before_publication

protected

  def game_starts_in_the_future
    if self.author_finished_at.nil? and self.starts_at and self.starts_at < Time.now
      self.errors.add(:starts_at, :in_the_past)
    end
  end

  def valid_max_num
    if self.max_team_number
      if self.max_team_number < self.requested_teams_number
        self.errors.add(:max_team_number, :exceeds_requested)
      end
    end
  end
  def deadline_is_in_future
    if self.author_finished_at.nil? and self.registration_deadline and self.registration_deadline < Time.now
        self.errors.add(:registration_deadline, :in_the_past)
    end
  end
  def deadline_is_before_game_start
    if self.registration_deadline and
        self.starts_at and self.registration_deadline > self.starts_at
      self.errors.add(:registration_deadline, :after_game_start)
    end
  end

private

  def available_locales_are_known
    known = I18n.available_locales.map(&:to_s)
    unknown = self.available_locale_list - known
    return if unknown.empty?

    self.errors.add(:available_locales,
                    I18n.t("activerecord.errors.models.game.attributes.available_locales.unknown",
                           :locales => unknown.join(", ")))
  end

  def available_locales_include_primary
    return if self.available_locale_list.include?(self.primary_locale.to_s)

    self.errors.add(:available_locales,
                    I18n.t("activerecord.errors.models.game.attributes.available_locales.missing_primary"))
  end

  # The columns hold the primary language's text. Repointing primary_locale
  # once translations exist would leave the columns holding one language while
  # the game claims another, and every fallback would then serve the wrong one.
  #
  # Checked across the WHOLE aggregate (game, levels, hints, questions), not
  # just ContentTranslation rows on the Game record itself. An author who has
  # translated every level and hint but never touched the game's own name/
  # description would otherwise still be allowed to repoint primary_locale --
  # after which every level column holds the old primary language while the
  # game claims a new one, exactly the corruption this guard exists to prevent.
  def primary_locale_is_settled
    return unless self.primary_locale_changed?
    return if self.new_record?
    return if self.draft? && translatable_records.none? { |record| record.content_translations.any? }

    self.errors.add(:primary_locale,
                    I18n.t("activerecord.errors.models.game.attributes.primary_locale.settled"))
  end

  # Fires only when publication state or the declared locale set changes, NOT on
  # every save. A state-only check (`return if draft?`) re-runs on every write to
  # the row, so adding a level to a published game left it permanently invalid --
  # and the fallout landed on saves that have nothing to do with translation:
  # reserve_place_for_team! silently stopped enforcing max_team_number, and
  # finish_game! and start_test raised.
  #
  # The three cases that must still be caught:
  #   - a game created already published (is_draft defaults to false and the
  #     new-game form leaves the box unchecked, so this is the common path)
  #   - a draft being published
  #   - a locale added to a game that is already live
  def declared_locales_are_translated_before_publication
    return if self.draft?
    return unless self.new_record? ||
                  self.is_draft_changed?(:from => true, :to => false) ||
                  self.available_locales_changed?

    missing = self.missing_translations
    return if missing.empty?

    self.errors.add(:base, I18n.t("games.translations.incomplete", :count => missing.size))
  end

  def translatable_records
    records = [ self ]
    # Nested, not sibling: includes(:hints, :questions, :content_translations)
    # preloads the LEVEL's translations but leaves each hint and question to
    # lazy-load its own, which is one query per record.
    self.levels.includes(:content_translations,
                         :hints => :content_translations,
                         :questions => :content_translations).each do |level|
      records << level
      records.concat(level.hints)
      records.concat(level.questions)
    end
    records
  end

  def label_for(record, field)
    field_name = I18n.t("games.translations.fields.#{field}")
    case record
    when Game     then I18n.t("games.translations.game_field",  :field => field_name)
    when Level    then I18n.t("games.translations.level_field", :position => record.position, :field => field_name)
    when Hint     then I18n.t("games.translations.hint_field",  :position => record.level&.position,
                                                                :minutes => record.delay_in_minutes)
    when Question then I18n.t("games.translations.question_field", :position => record.level&.position)
    end
  end
end
