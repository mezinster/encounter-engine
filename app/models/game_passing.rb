class GamePassing < ApplicationRecord
  # Rails 7.1+ requires the coder to be explicit, and plain `coder: YAML`
  # (Rails' safe-mode YAMLColumn) can only load/dump a small permitted-class
  # allowlist. This column used to hold full Question (ActiveRecord)
  # instances -- going back to the Merb app's unrestricted
  # `serialize :answered_questions` -- and a full AR object's dump embeds
  # adapter-internal type-cast classes (ActiveSupport::TimeWithZone,
  # ActiveRecord::ConnectionAdapters::SQLite3Adapter::SQLite3Integer here in
  # dev/test; entirely different PostgreSQL::OID::* classes in production).
  # That allowlist is neither small nor stable across adapters: permitting
  # exactly [Question, ActiveModel::Attribute::FromDatabase,
  # ActiveModel::Attribute::FromUser] (the minimal set for a single freshly
  # -reloaded record) still leaves 14 of the 97 examples in `spec/models/`
  # raising Psych::DisallowedClass, because the suite (like real gameplay
  # sequences) mixes freshly-built and freshly-loaded Question objects.
  #
  # unsafe_load would dodge that but turns any future write to this column
  # into remote code execution on the next read -- unacceptable given this
  # project has already seen intrusion attempts (see README).
  #
  # Instead of storing full model instances, this coder stores just the
  # question ids and resolves them back to Question records on load. Ids are
  # plain Integers inside an Array -- both permitted by Psych's built-in safe
  # defaults, no allowlist or adapter-specific class needed at all.
  #
  # Belt-and-braces: `load` also rescues Psych::DisallowedClass /
  # Psych::SyntaxError. A row written before this coder shipped can still
  # hold the old, unrestricted `serialize :answered_questions` format (full
  # YAML-dumped ActiveRecord objects); reading one of those with the new
  # coder would otherwise raise on every request that touches it, a 500 with
  # no recovery through the UI for whichever team is mid-level at deploy
  # time. Treating an unreadable value as "no questions answered yet" is the
  # same outcome an empty row already produces, so it is a safe default even
  # though it does lose that team's progress on the affected level.
  class AnsweredQuestionsCoder
    def self.dump(questions)
      YAML.dump(Array(questions).map(&:id))
    end

    def self.load(yaml)
      return [] if yaml.nil?

      ids = YAML.safe_load(yaml) || []
      by_id = Question.where(id: ids).index_by(&:id)
      ids.filter_map { |id| by_id[id] }
    rescue Psych::DisallowedClass, Psych::SyntaxError
      # A silently-dropped answered_questions column is exactly the support
      # case the comment above describes -- a team's progress on a level
      # disappearing with nothing in the UI to explain it. The coder itself
      # is handed only the raw column value, not the record it belongs to
      # (ActiveRecord::Type::Serialized#deserialize calls `coder.load(value)`
      # with no id in scope), so it can't name which row. GamePassing's
      # `warn_if_answered_questions_unreadable` after_find callback below
      # re-checks the same raw value with access to `id` and logs there --
      # this branch stays responsible only for making `load` itself safe.
      []
    end
  end

  serialize :answered_questions, coder: AnsweredQuestionsCoder, type: Array

  belongs_to :team, optional: true
  belongs_to :game, optional: true
  belongs_to :current_level, :class_name => "Level", optional: true

  scope :of_game, ->(game) { where(game_id: game) }
  scope :of_team, ->(team) { where(team_id: team) }
  scope :ended_by_author, -> { where(status: 'ended').order('current_level_id DESC') }
  scope :exited, -> { where(status: 'exited').order('finished_at DESC') }
  scope :finished, -> { where.not(finished_at: nil).order('finished_at ASC') }
  scope :finished_before, ->(time) { where('finished_at < ?', time) }

  before_create :update_current_level_entered_at

  before_save { self.answered_questions ||= [] }

  after_find :warn_if_answered_questions_unreadable

  def self.of(team, game)
    self.of_team(team).of_game(game).first
  end

  def check_answer!(answer)
    answer.strip!

    if correct_answer?(answer)
    	answered_question = current_level.find_question_by_answer(answer)
    	pass_question!(answered_question)
    	pass_level! if all_questions_answered?
    	true
   	else
    	false
    end
  end

  def pass_question!(question)
		answered_questions << question
		save!
  end

  def pass_level!
    if last_level?
      set_finish_time
    else
      update_current_level_entered_at
    end

    reset_answered_questions

    self.current_level = self.current_level.next
    save!
  end

  def finished?
    !! finished_at
  end

  # The clock every countdown is measured against. While a game is paused this
  # is the instant it was paused, so hints_to_show, upcoming_hints and
  # time_at_level all freeze together -- and get_current_level_tip returns an
  # unchanging state to every poll without knowing pausing exists.
  #
  # One concept instead of a filter on the tip endpoint that every future hint
  # code path would have to remember.
  def effective_now
    self.game&.paused_at || Time.now
  end

  def hints_to_show
    now = effective_now
    current_level.hints.select { |hint| hint.ready_to_show?(current_level_entered_at, now) }
  end

  def upcoming_hints
    now = effective_now
    current_level.hints.select { |hint| !hint.ready_to_show?(current_level_entered_at, now) }
  end

  def correct_answer?(answer)
    unanswered_questions.any? { |question| question.matches_any_answer(answer) }
  end

  def time_at_level
    difference = effective_now - self.current_level_entered_at
    hours, minutes, seconds = seconds_fraction_to_time(difference)
    "%02d:%02d:%02d" % [hours, minutes, seconds]
  end

  def unanswered_questions
		current_level.questions - answered_questions
	end

  def all_questions_answered?
    (current_level.questions - self.answered_questions).empty?
  end

  def exit!
    self.finished_at = Time.now
    self.status = "exited"
    self.save!
  end

  def exited?
    self.status == "exited"
  end

  def end!
    if !self.exited?
      self.status = "ended"
      self.save!
    end
  end

  # Operator interventions. Each leaves the record in a state ordinary
  # gameplay could also have produced -- that is the constraint the whole
  # feature is built on, and the reason there is no generic state editor.
  # Refusals raise ArgumentError; InterventionsController rescues it.

  def move_to_level!(level)
    raise ArgumentError, "level belongs to another game" unless level.game_id == self.game_id

    self.current_level = level
    self.answered_questions = []
    self.current_level_entered_at = Time.now
    # A team standing on a level is not finished. Clearing these here is what
    # keeps a moved team from being simultaneously mid-level and finished.
    self.finished_at = nil
    self.status = nil
    save!
  end

  def reinstate!
    # exit! leaves the entry clock alone, so without this reset a team that
    # quit an hour ago returns to a level with every hint already elapsed.
    self.current_level_entered_at = Time.now
    self.finished_at = nil
    self.status = nil
    save!
  end

  def reset_level_clock!
    raise ArgumentError, "team has finished" if self.finished?

    self.current_level_entered_at = Time.now
    save!
  end

protected

  def last_level?
    self.current_level.next.nil?
  end

  def update_current_level_entered_at
    self.current_level_entered_at = Time.now
  end

  def set_finish_time
  	self.finished_at = Time.now
  end

  def reset_answered_questions
    self.answered_questions.clear
  end

  # AnsweredQuestionsCoder.load silently returns [] when the column holds a
  # pre-coder legacy value it can't safely parse (see the coder's comment) --
  # by design, so one bad row can't 500 every request that touches it. But
  # silent is exactly wrong for anyone trying to find out why a team's
  # progress vanished, and the coder has no access to `id` to say which row.
  # Re-check the same raw value here, where `id` is in scope, purely to log.
  def warn_if_answered_questions_unreadable
    raw = read_attribute_before_type_cast(:answered_questions)
    return if raw.nil?

    YAML.safe_load(raw)
  rescue Psych::DisallowedClass, Psych::SyntaxError
    Rails.logger.warn(
      "GamePassing##{id}: answered_questions column holds an unreadable " \
      "(pre-coder legacy format?) value; treating it as no questions answered."
    )
  end

  # TODO: keep SRP, extract this to a separate helper
  def seconds_fraction_to_time(seconds)
    hours = minutes = 0
    if seconds >=  60 then
      minutes = (seconds / 60).to_i
      seconds = (seconds % 60 ).to_i

      if minutes >= 60 then
        hours = (minutes / 60).to_i
        minutes = (minutes % 60).to_i
      end
    end
    [hours, minutes, seconds]
  end

end
