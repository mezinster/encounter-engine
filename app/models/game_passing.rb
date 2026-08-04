class GamePassing < ActiveRecord::Base
  serialize :answered_questions

  belongs_to :team
  belongs_to :game
  belongs_to :current_level, :class_name => "Level"

  scope :of_game, ->(game) { where(game_id: game) }
  scope :of_team, ->(team) { where(team_id: team) }
  scope :ended_by_author, -> { where(status: 'ended').order('current_level_id DESC') }
  scope :exited, -> { where(status: 'exited').order('finished_at DESC') }
  scope :finished, -> { where.not(finished_at: nil).order('finished_at ASC') }
  scope :finished_before, ->(time) { where('finished_at < ?', time) }

  before_create :update_current_level_entered_at

  before_save { self.answered_questions ||= [] }

  # answered_questions is a serialised column, so it reads back as nil until
  # something writes it. The before_save above only covers persisted records,
  # which leaves reset_answered_questions (self.answered_questions.clear) and
  # answered_questions << question raising NoMethodError on a new record.
  # Always hand back a real array. Assigning through self[] rather than
  # returning a throwaway [] matters: << has to mutate the stored value.
  def answered_questions
    # Assign and then re-read rather than using ||=. For a serialised column
    # `self[:x] ||= []` evaluates to the assignment's own value -- the bare []
    # literal -- while ActiveRecord stores a type-cast copy of it. Callers
    # would then push onto an orphaned array and lose the first write.
    self[:answered_questions] = [] if self[:answered_questions].nil?
    self[:answered_questions]
  end

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

  def hints_to_show
    current_level.hints.select { |hint| hint.ready_to_show?(current_level_entered_at) }
  end

  def upcoming_hints
    current_level.hints.select { |hint| !hint.ready_to_show?(current_level_entered_at) }
  end

  def correct_answer?(answer)
    unanswered_questions.any? { |question| question.matches_any_answer(answer) }
  end

  def time_at_level
    difference = Time.now - self.current_level_entered_at
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
