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

  include TimeFormatting

  belongs_to :team, optional: true
  belongs_to :game, optional: true
  belongs_to :current_level, :class_name => "Level", optional: true
  belongs_to :game_run, :optional => true
  belongs_to :access_pass, :optional => true
  has_many :point_transactions

  scope :of_game, ->(game) { where(game_id: game) }
  scope :of_team, ->(team) { where(team_id: team) }
  scope :ended_by_author, -> { where(status: 'ended').order('current_level_id DESC') }
  scope :exited, -> { where(status: 'exited').order('finished_at DESC') }
  scope :finished, -> { where.not(finished_at: nil).order('finished_at ASC') }
  scope :finished_before, ->(time) { where('finished_at < ?', time) }

  # --- What became of a passing -----------------------------------------
  #
  # Three mutually exclusive scopes covering every row, for anything counting
  # outcomes rather than listing them (the admin overview today). The naive
  # pair -- finished_at present / finished_at nil -- gets this wrong twice, and
  # both mistakes are visible on that page:
  #
  #   #end! sets status "ended" and does NOT stamp finished_at, so a team the
  #   author ended mid-course reads as still playing, for ever. That is the
  #   reported bug: an instance whose only game was finished, with nothing
  #   running, reporting three passings in progress.
  #
  #   #exit! stamps finished_at as well as the status, so a team that walked
  #   off the course reads as having completed it.
  #
  # And the wrinkle that decides how "ended" is read: GamesController#end_game
  # calls end! on EVERY passing of the run, and end! skips only exited ones --
  # so a team that genuinely crossed the finish line also carries status
  # "ended" once the author closes the game. "ended" therefore cannot mean
  # "did not finish" by itself. finished_at says whether the course was
  # completed; exited? separates crossing the line from walking off it. That
  # is the same pair GamePassingsHelper#full_log_visible? and
  # LogsController#ensure_full_log_access already use for "genuinely
  # finished".
  #
  # Every `.not` below is spelled with an explicit nil branch. status is
  # nullable and nil is the ordinary in-progress value, so a bare
  # `where.not(status: ...)` generates NOT IN / !=, which is NULL -- and so
  # false -- for every nil-status row under SQL's three-valued logic. That
  # would silently drop the entire population of a running game.
  # spec/models/game_passing/outcome_scopes_spec.rb pins all of this,
  # including that the three still add up.
  scope :completed, -> {
    done = where.not(:finished_at => nil)
    done.where(:status => nil).or(done.where.not(:status => "exited"))
  }
  scope :interrupted, -> {
    where(:status => "exited").or(where(:status => "ended", :finished_at => nil))
  }
  scope :in_progress, -> {
    unfinished = where(:finished_at => nil)
    unfinished.where(:status => nil).or(unfinished.where.not(:status => %w[exited ended]))
  }

  # The Ruby twins of `completed` and `interrupted`, for a view holding one
  # loaded row rather than a relation. They exist so that "finished" is ONE
  # notion in this application: the public team page used to ask
  # `passing.finished_at` on its own and so printed a finish time for a run
  # the chart, asking `GamePassing.completed`, counted as never completed --
  # two screens one link apart disagreeing about the same row. See the
  # whole-branch review, F2.
  #
  # Deliberately re-expressed rather than delegated to the scopes (which would
  # cost a query per row on a page that renders a table of them); the pair is
  # small enough to mirror by hand and
  # spec/models/game_passing/outcome_scopes_spec.rb pins that each predicate
  # agrees with its scope on the same row, so a change to one that is not made
  # to the other goes red.
  def completed?
    finished? && !exited?
  end

  def interrupted?
    exited? || (self.status == "ended" && !finished?)
  end

  # Passings on ORDINARY runs -- everything a rehearsal produced is left out.
  #
  # The counterpart of #award_points_for's `return if game_run&.is_testing?`:
  # a testing run writes no ledger row, so counting its passings among a
  # team's games started/finished made the public chart read "1 game started,
  # 1 finished, 0 points" for a team that had never played anything real.
  #
  # game_run is :optional and nil means an ORDINARY run, so the nil branch is
  # spelled out. A bare `where.not(:game_run_id => testing)` generates
  # NOT IN, which is NULL -- and so false -- for a NULL game_run_id under
  # SQL's three-valued logic, and would silently drop every run-less passing:
  # the same three-valued trap the outcome scopes above document.
  #
  # A subquery rather than a join, for the same reason Game.visible uses one:
  # this composes with `completed` and with `group(:team_id)` without a second
  # reference to game_runs.
  scope :not_testing, -> {
    testing = GameRun.where(:is_testing => true).select(:id)
    where(:game_run_id => nil).or(where.not(:game_run_id => testing))
  }

  # THE single definition of "this team's current attempt at a gated game" --
  # finding 3 of the whole-branch review. Three call sites each invented
  # their own resolution: GamePassingsController#gated_passing (first
  # unspent, unordered), LogsController#gated_passing_for
  # (order(:id => :desc)), InterventionsController#find_game_passing (no
  # order at all). Spec B6 allows a team to hold several attempts for one
  # game (a fresh pass after the first is spent), so those three could pick
  # DIFFERENT rows once a team held two -- and under SQLite's insertion-order
  # default, the unordered form picked the OLDEST, already-completed one.
  #
  # Newest first (id, not created_at -- the column every other id-based
  # ordering in this codebase, e.g. LogsController's old form, already used),
  # and that is provably the LIVE attempt whenever a live one exists:
  # #gated_passing only ever creates a new attempt once every existing one is
  # spent ("return live if live" -- a fresh pass is never touched while an
  # unspent attempt exists), so at any moment at most the highest-id attempt
  # can be unspent. Every older one is therefore guaranteed spent, which
  # makes "newest" and "the live one, else the most recently finished one"
  # the SAME resolution rather than two that happen to agree today:
  #   * GamePassingsController#gated_passing serves it unchanged when live,
  #     and otherwise correctly falls through to mint a new attempt.
  #   * LogsController's full-log access is judged by it, live or spent --
  #     a team currently playing a second attempt must not read the log of a
  #     finished first one, and a team whose newest attempt is finished
  #     reads that one's log, never an older attempt's.
  #   * InterventionsController's move/reinstate/reset_clock act on it --
  #     "reinstate" in particular exists to un-spend a team's most recent
  #     attempt, never an older one they have already replaced.
  #
  # where.not(:access_pass_id => nil) excludes a stray runless passing that
  # is not a gated attempt at all (there is no other way to reach one, but
  # nothing enforces that here). team may be a Team or a raw id, matching
  # of_team's own flexibility -- InterventionsController has only
  # params[:team_id] on hand and this spares it an extra Team.find.
  def self.gated_attempt_for(game, team)
    return nil if team.nil?

    of_game(game).of_team(team).where.not(:access_pass_id => nil).order(:id => :desc).first
  end

  before_create :update_current_level_entered_at

  before_save { self.answered_questions ||= [] }

  after_find :warn_if_answered_questions_unreadable

  def check_answer!(answer)
    answer.strip!

    if correct_answer?(answer)
    	answered_question = current_level.find_question_by_answer(answer)
    	pass_question!(answered_question)
    	pass_level! if level_answered?
    	true
   	else
    	false
    end
  end

  # The quiz counterpart of check_answer!, which takes a typed string and is
  # left completely untouched -- a level with no options never reaches here.
  #
  # Set equality, not overlap: every correct option and no incorrect one.
  # Partial credit was considered and rejected -- this product ranks teams by
  # elapsed time and has no concept of a score, so "partly right" has nowhere
  # to go.
  def answer_options!(question, option_ids)
    chosen = Array(option_ids).map(&:to_i).uniq.sort

    if chosen.any? && chosen == question.correct_option_ids
      pass_question!(question)
      pass_level! if level_answered?
      true
    else
      # Charged on every wrong submission, including a repeat of one already
      # tried: forgiving repeats would let a team walk the whole option space
      # for the price of a single mistake.
      #
      # An atomic UPDATE ... SET penalty_seconds = penalty_seconds + amount,
      # not read-modify-write: two teammates submitting a wrong answer at the
      # same instant each read the same starting value under update_column, so
      # one charge is lost. increment! issues the increment as SQL (via
      # update_counters under the hood) rather than writing back a value
      # computed from this process's possibly-stale in-memory copy, and, like
      # update_column, runs no validations or callbacks (save! would rewrite
      # answered_questions as a side effect). Deliberately NOT touching
      # current_level_entered_at: that column is the sole input to every hint
      # countdown, so charging a penalty against it would bring the next hint
      # CLOSER on a wrong answer.
      increment!(:penalty_seconds, question.level.wrong_answer_penalty.to_i)
      false
    end
  end

  def pass_question!(question)
		answered_questions << question
		save!
  end

  def pass_level!
    passed    = self.current_level
    finishing = last_level?

    advance!(finishing)

    award_points_for(passed, finishing)
  end

  # Returns the level that was skipped.
  #
  # The fine is charged BEFORE the advance, which is the reverse of what
  # pass_level! does with its award, and the reversal is deliberate. An award
  # that fails to write is a bookkeeping problem: the team answered correctly
  # and must move on regardless. A FINE that fails to write hands out the thing
  # it exists to price -- and because skips_left counts these rows, an
  # unrecorded skip also makes the cap unenforceable.
  #
  # Charging first is safe only because refusing a skip is a no-op: the team
  # stays on a level they can still play. That is what separates this from
  # refusing to advance on a correct answer.
  #
  # If the charge succeeds and the advance then fails, the team retries: the
  # partial unique index refuses the second row, award! returns nil, and the
  # advance runs. One charge, no stuck team, and no transaction around the two
  # -- see PointTransaction.award!, which must not be rescued from inside one.
  # The paused refusal lives HERE, not in a controller filter, and that is the
  # point of it. GamePassingsController carries ensure_game_not_paused; the
  # operator's InterventionsController deliberately treats a paused game as
  # live (a resume must stay reachable), so the same rule expressed as a filter
  # protected one of the two ways into this method and an operator could skip
  # for a team mid-pause. advance! stamps current_level_entered_at from
  # Time.now while every countdown reads effective_now -- paused_at -- so the
  # team's clock came out negative and Game#resume! then shifted it further
  # into the future, delaying every hint on the level they had just been given.
  # Refusing here holds on both paths by construction. Spec section 3 asks for
  # this refusal in the model for that reason.
  #
  # Narrow to paused ON PURPOSE: the other senses of "not currently running" --
  # not yet started, draft, withdrawn, author-finished -- are refused on both
  # paths by ensure_game_is_started / ensure_game_is_live already, and a
  # testing run is skippable BY DESIGN (S7), which a general "the game must be
  # running" predicate would break.
  def skip_level!(actor)
    raise ArgumentError, "game is paused" if game.paused?
    raise ArgumentError, "team has exited" if exited?
    raise ArgumentError, "no skips left" unless skips_left.positive?

    skipped = self.current_level
    raise ArgumentError, "nothing to skip" if skipped.nil?

    charge_skip!(skipped, actor)
    advance!(last_level?)
    log_skip!(skipped)

    skipped
  end

  # Derived, never stored. The partial unique index on
  # (game_passing_id, level_id, reason) already guarantees one row per skipped
  # level, so counting rows IS the count of skips -- a column would be a second
  # account of the same fact, free to drift from it.
  def skips_left
    game.max_skips.to_i - point_transactions.where(:reason => "level_skipped").count
  end

  def finished?
    !! finished_at
  end

  # What ranking compares. For every game that predates quiz levels
  # penalty_seconds is 0, so this is finished_at unchanged.
  def effective_finished_at
    return nil unless self.finished_at

    self.finished_at + self.penalty_seconds.to_i
  end

  # What commercial standings rank on. NOT effective_finished_at, which is an
  # absolute timestamp: every pass starts when its own team opens the play
  # screen, so comparing instants would place a team that played in August
  # behind one that played in March however fast it was. GameRun#place_of's
  # comment records that exact defect.
  #
  # paused_seconds is subtracted because an operator pausing the game is not
  # the customer's doing; penalty_seconds is added for the same reason it is
  # added to effective_finished_at.
  def duration
    return nil unless self.finished_at

    (self.finished_at - self.created_at).round - self.paused_seconds.to_i + self.penalty_seconds.to_i
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

  # Only questions that are still answered by TYPING a code. A question keeps
  # its Answer rows after an author turns it into a quiz question by adding
  # options -- AnswersController#delete refuses to remove the last variant, so
  # there is no way to strip them even deliberately. Without this filter the
  # pre-quiz code stays a working answer to a quiz question, letting a team
  # finish a quiz level by typing a string the screen never asks for.
  def correct_answer?(answer)
    unanswered_questions.reject(&:quiz?).any? { |question| question.matches_any_answer(answer) }
  end

  def time_at_level
    seconds_to_hms(effective_now - self.current_level_entered_at)
  end

  def unanswered_questions
		current_level.questions - answered_questions
	end

  # Whether the team has done enough to pass this level.
  #
  # Renamed from all_questions_answered?: under any_code_passes that name would
  # state something false, and this is the only question either caller asks.
  #
  # Deliberately evaluated only when a team SUBMITS. Flipping a level's mode
  # does not re-evaluate existing passings -- see
  # docs/superpowers/specs/2026-08-06-redundant-codes-design.md §2. A team
  # holding one of three codes when an operator flips to "any" passes on their
  # next correct code, rather than being teleported forward by somebody else's
  # click (which would also restamp current_level_entered_at and rewrite every
  # hint countdown mid-level).
  def level_answered?
    return answered_questions.any? if current_level.any_code_passes?

    (current_level.questions - answered_questions).empty?
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
    self.current_level_entered_at = effective_now
    # A team standing on a level is not finished. Clearing these here is what
    # keeps a moved team from being simultaneously mid-level and finished.
    self.finished_at = nil
    self.status = nil
    save!
  end

  def reinstate!
    # exit! leaves the entry clock alone, so without this reset a team that
    # quit an hour ago returns to a level with every hint already elapsed.
    self.current_level_entered_at = effective_now
    self.finished_at = nil
    self.status = nil
    save!
  end

  def reset_level_clock!
    raise ArgumentError, "team has finished" if self.finished?

    self.current_level_entered_at = effective_now
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

  # What "advance" means, in one place. pass_level! and skip_level! differ only
  # in what they do BEFORE and AFTER this: a pass awards afterwards, a skip
  # charges beforehand. Extracted rather than copied because this repository has
  # already shipped one concept resolved two ways -- finished_at versus
  # status "exited", which disagreed across two surfaces until a review caught
  # it -- and a second copy of this would be the same bet.
  #
  # `finishing` is passed in rather than recomputed: the caller reads it before
  # current_level moves, and after the move the answer would be wrong.
  def advance!(finishing)
    if finishing
      set_finish_time
    else
      update_current_level_entered_at
    end

    reset_answered_questions

    self.current_level = self.current_level.next
    save!
  end

  # NOT gated on points_enabled, and that is a considered difference from
  # award_points_for. That gate exists so no EXISTING game starts writing rows
  # behind its author's back; a skip row cannot be written unless the author
  # set max_skips > 0, which is the opt-in. points_enabled gates awards; it
  # does not gate the record of a team's own action.
  #
  # With points off the AMOUNT is zeroed rather than the row skipped entirely:
  # points_enabled is the master switch for the whole points system, and a
  # game with it off gives a team no way to EARN -- so charging the ordinary
  # fine would drain a balance the team built in other games, for a game that
  # could never add to it. The four skip settings are independent form
  # fields with no cross-validation (see Game's validations), so
  # points_enabled: false, skip_points_fine: 25 is reachable by ordinary
  # misconfiguration. The row is still written at amount 0, because the cap
  # (skips_left) still needs it to count.
  #
  # Testing runs write these rows for the same reason: without them the cap has
  # nothing to count, and an author testing the limit they configured would see
  # no limit. finish_test and TestAdmission#revoke! delete a run's
  # point_transactions, so nothing outlives the test.
  #
  # increment!, not read-modify-write, for the reason answer_options! records
  # at this same column: two teammates acting at the same instant under
  # update_column each read the same starting value and one charge is lost.
  #
  # Guarded on award! returning a row, not fired unconditionally: award!
  # returns nil when the partial unique index refuses a duplicate -- a retry
  # after a failed advance (S5's self-heal), or an operator re-skip landing a
  # team back on a level it already paid for. Firing the increment regardless
  # double-charges the team's clock on exactly the path S5 promises is a
  # single charge. The ledger row is the single arbiter of "already charged
  # for this level" -- the same one skips_left already relies on.
  def charge_skip!(level, actor)
    amount = game.points_enabled? ? -game.skip_points_fine.to_i : 0

    row = PointTransaction.award!(:passing    => self,
                                  :reason     => "level_skipped",
                                  :level      => level,
                                  :amount     => amount,
                                  :created_by => actor)
    return if row.nil?

    penalty = game.skip_time_penalty.to_i
    increment!(:penalty_seconds, penalty) if penalty.positive?
  end

  # The level log is what an author reads to see what a team did, and a level
  # that simply stops having answers looks like a team that went quiet. AFTER
  # the advance, not before: the log line is a record, and a record of a skip
  # that did not happen is worse than a missing one.
  #
  # `answer` holds a fixed ASCII marker rather than a t() call. This is STORED
  # data, read later by everyone who opens the log, so a translated string
  # would freeze whichever locale the acting user happened to be using into a
  # row that outlives their session -- the same reasoning as
  # TestAdmission.disposable_team_name.
  def log_skip!(level)
    Log.create!(:game_id         => game_id,
                :game_run_id     => game_run_id,
                :game_passing_id => id,
                :level           => level.name,
                :level_id        => level.id,
                :team            => team.name,
                :team_id         => team_id,
                :time            => Time.now,
                :answer          => "(skipped)")
  end

  # Awards are written AFTER the advance is saved, deliberately. A team
  # standing in a street with a correct answer must move on whether or not the
  # ledger accepts a row; nothing about scoring may block play.
  #
  # PointTransaction.award! returns nil on a duplicate rather than raising, so
  # a re-passed level -- an operator sent them back -- awards once and the team
  # still advances. See the design, P5.
  def award_points_for(level, finishing)
    return unless game&.points_enabled?

    # A testing run's awards would be real, permanent rows -- the ledger
    # never reverses (see PointTransaction's class comment). Team#deletable?
    # requires point_transactions.empty?, so a solo author who passes even
    # one level while test-running a points-enabled game leaves the
    # disposable "nickname (test #N)" team permanently undeletable, and both
    # TestAdmission#revoke! and GameRun#sweep_test_admissions! skip it
    # silently because deletable? is false -- a phantom team holding points
    # in the global chart forever. game_run is optional (belongs_to
    # :game_run, :optional => true), and nil means an ORDINARY run, so this
    # is `&.is_testing?`, not `.nil? || ...is_testing?` -- either of those
    # forms would also switch off every passing that has no game_run at all.
    return if game_run&.is_testing?

    PointTransaction.award!(:passing => self, :reason => "level_completed",
                            :level => level, :amount => game.points_for_level(level))

    return unless finishing

    PointTransaction.award!(:passing => self, :reason => "game_completed",
                            :level => nil, :amount => game.game_completion_points)
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

end
