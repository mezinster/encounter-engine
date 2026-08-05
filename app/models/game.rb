# -*- encoding : utf-8 -*-
class Game < ApplicationRecord
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

  validate :available_locales_are_known
  validate :available_locales_include_primary
  validate :primary_locale_is_settled

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
  def primary_locale_is_settled
    return unless self.primary_locale_changed?
    return if self.new_record?
    return if ContentTranslation.where(:translatable => self).none? && self.draft?

    self.errors.add(:primary_locale,
                    I18n.t("activerecord.errors.models.game.attributes.primary_locale.settled"))
  end
end
