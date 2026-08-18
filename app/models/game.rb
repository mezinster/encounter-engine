# -*- encoding : utf-8 -*-
class Game < ApplicationRecord
  include TranslatableContent

  TRANSLATABLE_FIELDS = %w[name description].freeze

  VISIBILITIES = %w[draft listed].freeze

  ACCESS_MODES = %w[scheduled pass_required].freeze

  # Not a boolean: these entries are simultaneously the publish gate's reason
  # for refusing and the author's to-do list, so they carry enough to render a
  # deep link straight to the offending field.
  MissingTranslation = Struct.new(:record, :field, :locale, :label)

  def translation_game
    self
  end

  belongs_to :author, class_name: "User", optional: true
  has_many :levels, -> {  order('position') }, :dependent => :destroy

  # A Game is CONTENT; a GameRun is one running of it. The schedule lives on
  # the run from phase 1 onwards -- see
  # docs/superpowers/specs/2026-08-10-game-runs-phase-1-design.md.
  #
  # autosave: true is load-bearing, not decoration. has_many saves NEW children
  # on parent save but leaves CHANGED persisted ones alone, so without it
  # `game.starts_at = x; game.save` would silently not persist -- and that is
  # exactly the path the edit form and several frozen scenarios drive.
  #
  # inverse_of is required on both sides: the scope below and the name mismatch
  # (:runs -> GameRun) each independently defeat Rails' automatic inverse
  # detection, and GameRun validates the presence of its game.
  has_many :runs, -> { order(:ordinal) },
           :class_name => "GameRun", :inverse_of => :game,
           :autosave => true, :dependent => :destroy

  # The eight scheduling columns now live on the run. These delegations are why
  # nothing else in the application had to change: Game#status, #started?,
  # #paused?, #author_finished?, every view and every controller keep reading
  # the same method names.
  #
  # The four schedule validations (game_starts_in_the_future,
  # deadline_is_in_future, deadline_is_before_game_start, valid_max_num)
  # deliberately stay on Game and read through these -- see the design, D4.
  delegate :starts_at, :starts_at=,
           :registration_deadline, :registration_deadline=,
           :max_team_number, :max_team_number=,
           :requested_teams_number, :requested_teams_number=,
           :author_finished_at, :author_finished_at=,
           :is_testing, :is_testing=,
           :test_date, :test_date=,
           :test_token, :test_token=,
           :paused_at, :paused_at=,
           :to => :current_run
  has_many :logs, -> { order('time') }
  has_many :game_entries, :class_name => "GameEntry", :dependent => :destroy
  has_many :game_passings, :class_name => "GamePassing"
  has_many :game_files, :dependent => :destroy
  has_many :translation_runs, :dependent => :destroy
  has_many :access_passes, :dependent => :destroy

  validates :name, presence: true, uniqueness: true
  validates :description, presence: true
  validates :max_team_number, numericality: { greater_than: 0, less_than: 10000 }
  validates :author, presence: true
  validates :visibility, :inclusion => { :in => VISIBILITIES }
  validates :access_mode, :inclusion => { :in => ACCESS_MODES }

  validate :game_starts_in_the_future
  validate :valid_max_num

  validate :deadline_is_in_future
  validate :deadline_is_before_game_start

  scope :by, ->(author) { where(author_id: author) }
  scope :non_drafts, -> { where(:visibility => "listed") }
  # Joins each game to its CURRENT run -- the highest ordinal. Every scope and
  # counter that filters on a schedule column goes through this, so there is one
  # definition of "the run that speaks for this game" in SQL rather than one per
  # query. LEFT, not inner: a game whose run is somehow missing must still
  # appear, or a listing silently loses rows.
  scope :with_current_run, -> {
    joins(<<~SQL)
      LEFT JOIN game_runs ON game_runs.game_id = games.id
        AND game_runs.ordinal = (SELECT MAX(r2.ordinal) FROM game_runs r2
                                  WHERE r2.game_id = games.id)
    SQL
  }

  # author_finished_at moved to the run, so this can no longer read a games
  # column. It kept returning nothing at all for a while after the move --
  # silently, because an empty result looks like "no finished games" rather
  # than like a bug.
  scope :finished, -> { with_current_run.includes(:runs).where("game_runs.author_finished_at IS NOT NULL") }

  # The single place "may a player see this?" is answered. non_drafts stays as
  # it is -- other callers use it for its literal meaning -- and this composes
  # on top, so a future caller that forgets `visible` is a visible mistake
  # rather than a silent leak.
  #
  # A game in TEST mode is excluded, and that clause is why this comment grew.
  # start_test sets visibility to "listed" so the game behaves as live, which silently
  # retires the non_drafts protection above at exactly the moment the game is
  # an unpublished rehearsal -- it was listed on the public home page as
  # RUNNING, reported from production 2026-08-15. shared/_current_games.html
  # .erb had always skipped testing games by hand; this makes the whole
  # application agree with that partial instead of only one screen doing so.
  #
  # A SUBQUERY, not with_current_run's LEFT JOIN, and the difference is
  # practical rather than stylistic: `visible` is composed freely -- merged
  # into another relation in GamesController#index, chained with includes(:runs)
  # in .started and .notstarted -- and a second join on game_runs from any of
  # those directions raises "table name game_runs specified more than once".
  # A subquery composes with anything.
  #
  # "Any run is testing", not "the current run is testing": only the current
  # run can carry the flag, because start_test and finish_test are its only
  # writers and both act on current_run. Where the two could ever differ, this
  # form hides the game and the other would expose it -- the safe direction.
  scope :visible, -> {
    non_drafts.where(:withdrawn_at => nil)
              .where.not(:id => GameRun.where(:is_testing => true).select(:game_id))
  }

  # includes(:runs) because started? now reads the run. Without it this issues
  # one SELECT per game -- and both callers render a list, so the cost scales
  # with the size of the instance.
  def self.started
    Game.visible.includes(:runs).select(&:started?)
  end

  def draft?
    self.visibility == "draft"
  end

  def listed?
    self.visibility == "listed"
  end

  def pass_required?
    self.access_mode == "pass_required"
  end

  # A draft has not begun, whatever the clock says: the start date on an
  # unpublished game is a plan, not an event.
  #
  # The draft guard is not belt-and-braces. game_starts_in_the_future runs on
  # save and nowhere else, so a draft saved with a start date in the future
  # simply AGES past it -- no unusual action needed, just time. Without this
  # line such a game reported :draft from #status (which gives draft
  # precedence) while every caller of #started? treated it as running: the
  # dashboard offered "Завершить игру" and the stats, live channel and log
  # links, and ensure_game_was_not_started answered 401 to the author's own
  # edit, add-level and quiz-import. That filter has no superadmin exemption,
  # so the draft was locked for everyone, including the operator brought in to
  # rescue it. Reported from production 2026-08-10.
  #
  # DRAFTS ONLY, deliberately. Withdrawal is what an operator does TO a running
  # game -- see the comment on withdraw! -- so a withdrawn game has certainly
  # started, and reporting otherwise would change behaviour under a live race.
  # ensure_game_is_live already excludes withdrawn separately, which is where
  # that distinction belongs.
  #
  # Nothing downstream shifts: #status short-circuits on draft? before it ever
  # reaches here, Game.started and .not_started compose this with .visible,
  # which excludes drafts already, and start_test sets visibility to "listed"
  # before it moves starts_at, so a test run is never a draft.
  def started?
    return false if draft?

    self.starts_at.nil? ? false : Time.now > self.starts_at
  end

  def editing_locked?
    self.editing_locked_at.present?
  end

  # The run everything about the schedule reads and writes. Autobuilds rather
  # than returning nil because 70 places across spec/ and features/ construct
  # games as Game.new(:starts_at => ...) before any run could exist, and the
  # delegated writer has to land somewhere.
  #
  # runs.to_a.last, NOT runs.last, and the difference is a bug rather than a
  # style preference: runs.last on an unloaded association issues
  # SELECT ... ORDER BY ordinal DESC LIMIT 1 and cannot see a record that has
  # only been built in memory, so the second call would build a SECOND run and
  # autosave would persist both. to_a calls load_target, which merges unsaved
  # new records into the loaded target.
  #
  # "Current" is the highest ordinal, not "the one that is not finished" --
  # deterministic, and still correct in phase 3 when a second run exists.
  def current_run
    runs.to_a.last || runs.build(:ordinal => 1)
  end

  def paused?
    self.paused_at.present?
  end

  # update_column, not update!, and this is not a style preference: a running
  # game does not pass its own validations. game_starts_in_the_future adds an
  # error whenever author_finished_at is nil and starts_at is in the past --
  # true of every game being played. update! would raise RecordInvalid on
  # exactly the games pause exists for, and update would fail silently, the
  # same trap that makes reserve_place_for_team! stop enforcing
  # max_team_number once a game starts.
  def pause!
    raise ArgumentError, "already paused" if self.paused?

    current_run.update_column(:paused_at, Time.now)
  end

  # Shifting current_level_entered_at forward by the held duration is exactly
  # equivalent to not counting the paused interval, because that column is the
  # only input to every countdown.
  #
  # Transactional deliberately -- and this is the OPPOSITE call from the audit
  # write in AdminAudit, which is kept out of its action's transaction so a
  # logging failure cannot block an administrative change. Here the shift IS
  # the operation: a half-applied resume would hand some teams their countdown
  # back and silently rob others, and nothing downstream could tell.
  def resume!
    raise ArgumentError, "not paused" unless self.paused?

    transaction do
      held = Time.now - self.paused_at
      # finished_at excludes both finished and exited teams; neither has a
      # running clock. update_column because this is a mechanical bulk shift.
      # The current run's passings: only they have running clocks to shift.
      current_run.passings.where(:finished_at => nil).find_each do |gp|
        gp.update_column(:current_level_entered_at, gp.current_level_entered_at + held)
      end
      current_run.update_column(:paused_at, nil)
    end
  end

  def withdrawn?
    self.withdrawn_at.present?
  end

  # These four carry the same update_column reasoning as pause! above, and for
  # a sharper reason: an operator withdraws or freezes a game precisely BECAUSE
  # it is running badly, so a live game is the normal case here, not the edge
  # one. They shipped using update!, which meant every one of them raised
  # RecordInvalid -- a bare 422 in the browser -- on any game that had actually
  # started. On a draft they worked, which is why the specs stayed green:
  # create_game defaults starts_at to 2099, so no example had ever exercised a
  # started game. spec/requests/withdrawal_spec.rb now does.
  def withdraw!
    update_column(:withdrawn_at, Time.now)
  end

  def restore!
    update_column(:withdrawn_at, nil)
  end

  # The reverse of finish_game!, superadmin-only (see GamesController). Same
  # update_column shape as withdraw!/restore! -- deliberately unvalidated,
  # because game_starts_in_the_future and deadline_is_in_future are skipped
  # while author_finished_at is set, so a game ended after its start date
  # carries past dates a validated save would reject. For the "ended too
  # early, let it continue" case those past dates are correct, not stale.
  def unfinish!
    current_run.update_column(:author_finished_at, nil)
  end

  # The ONLY writer of author_id after creation, mirroring Team#set_captain!.
  # A game with two ways to change its author is a game whose access control
  # cannot be reasoned about from one place -- and author_id is what
  # ensure_author, ensure_author_if_game_draft and every author-only screen
  # ultimately read.
  #
  # update_column, not update!, carrying exactly the reasoning on withdraw!
  # above and for a sharper reason: the superadmin path has NO lifecycle
  # refusals, so this is reached on running games, and a running game fails
  # game_starts_in_the_future. update! would raise RecordInvalid on precisely
  # the games the operator path exists for.
  #
  # The assignment after the write keeps the in-memory record agreeing with the
  # row -- update_column writes the column but leaves the loaded association
  # pointing at the previous author, so a caller rendering game.author straight
  # afterwards would name the wrong person.
  def transfer_authorship_to!(user)
    raise ArgumentError, "no user" if user.nil?

    update_column(:author_id, user.id)
    self.author = user
    user
  end

  # The single writer that creates a run, mirroring transfer_authorship_to!
  # above. Nothing else builds one except Game#current_run's autobuild, which
  # only ever produces the first.
  #
  # Deliberately does no refusing: whether this game is ALLOWED a new run --
  # its current one finished, at least one level -- is the caller's question,
  # and Admin::GamesController#open_run answers it before anything changes, the
  # shape every administrative action in this codebase uses.
  # save!(context: :open) rather than create!: GameRun's schedule rules live in
  # the :open context, so they hold an operator opening a run to a future start
  # date and a real team cap, without ever firing on a run that merely exists
  # with a past date -- which is what every finished run is.
  def open_run!(attrs)
    run = runs.build(attrs.merge(:ordinal => runs.reload.maximum(:ordinal).to_i + 1))
    run.save!(:context => :open)
    run
  end

  def lock_editing!
    update_column(:editing_locked_at, Time.now)
  end

  def unlock_editing!
    update_column(:editing_locked_at, nil)
  end

  # Logs and game passings are players' history, not the author's content, and
  # destroy would orphan them rather than remove them -- there are no foreign
  # keys and no dependent: option on those associations. Withdrawal achieves
  # what deletion is usually reached for, without leaving unreachable rows.
  def deletable?
    self.game_passings.empty?
  end

  def created_by?(user)
    user.author_of?(self)
  end

  # Results belong to a run; the reasoning that used to live here moved with
  # them to GameRun. These answer for the CURRENT run, which is what every
  # caller reached by a game-id URL means -- phase 3 introduces the screens
  # that name a run explicitly.
  def finished_teams
    current_run.finished_teams
  end

  def place_of(team)
    current_run.place_of(team)
  end

  def self.notstarted
    Game.visible.includes(:runs).reject(&:started?)
  end

  # The single source of truth for what a game IS. The predicates overlap by
  # construction -- a withdrawn game may also be finished, a draft may have a
  # start time in the past -- so the ORDER is load-bearing, not stylistic.
  #
  # paused? and editing_locked? are deliberately NOT here: a game can be
  # paused AND running, and folding either in would hide one fact in order to
  # show the other. Both are reported alongside the status, never instead of
  # it -- the same reasoning count_by_status below documents for locking.
  #
  # count_by_status below applies this same precedence in SQL, because
  # counting must not load every row. The two are pinned to each other by
  # spec/models/game/status_spec.rb rather than by a comment asking future
  # readers to keep them in step.
  def status
    return :withdrawn if withdrawn?
    return :draft     if draft?
    return :finished  if author_finished?
    # A gated game is never "scheduled": it has no start date to wait for and
    # no cohort to wait with. Placed after :finished so an operator who closes
    # a commercial game still sees it reported as finished, and before
    # :running so the schedule rungs below stay purely about scheduled games.
    return :available if pass_required?
    return :running   if started?
    :scheduled
  end

  # Each game counts once, under the first status that matches, in this order:
  # withdrawn, draft, finished, running, scheduled. The predicates overlap by
  # construction -- a draft has no start time in the past, a withdrawn game may
  # also be finished -- so without a precedence the columns would not sum to
  # the total and nobody would notice.
  #
  # The order matches Game#status above, which is what every screen uses to
  # label an individual game. Counting is done in SQL rather than through
  # that method because a counter must not load every row.
  #
  # Counted in SQL. Game.started and Game.notstarted just above load every row
  # and filter in memory, which is fine for a listing of two and wrong for a
  # counter -- do not build counts on them.
  def self.count_by_status(now = Time.now)
    # LEFT JOIN, not an inner one: a game whose run is somehow missing must
    # still be counted, or the columns silently stop summing to the total --
    # which is the one thing a status table must never do. The MAX(ordinal)
    # condition picks the current run and is also what stops a game with two
    # runs being counted twice.
    live       = with_current_run.where(:withdrawn_at => nil)
    published  = live.where(:visibility => "listed")
    unfinished = published.where("game_runs.author_finished_at IS NULL")

    {
      # Unjoined: withdrawn_at is still a games column, so this needs no run.
      :withdrawn => where.not(:withdrawn_at => nil).count,
      :draft     => live.where(:visibility => "draft").count,
      :finished  => published.where("game_runs.author_finished_at IS NOT NULL").count,
      :available => unfinished.where(:access_mode => "pass_required").count,
      # starts_at is nullable and Game#started? treats NULL as not started, so
      # the NULL check is explicit rather than left to a comparison that would
      # evaluate to unknown and drop the row from every bucket.
      :running   => unfinished.where(:access_mode => "scheduled")
                              .where("game_runs.starts_at IS NOT NULL")
                              .where("game_runs.starts_at < ?", now).count,
      :scheduled => unfinished.where(:access_mode => "scheduled")
                              .where("game_runs.starts_at IS NULL OR game_runs.starts_at >= ?", now).count
    }
  end

  # Reported alongside the status table rather than as a row in it: a game can
  # be locked AND running, and forcing it into the precedence above would hide
  # one fact in order to show the other.
  def self.editing_locked_count
    where.not(:editing_locked_at => nil).count
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

  # Returned an Array -- always truthy -- because the capacity comparison's
  # result was computed and discarded, and a stray `Game.all.select` was the
  # method's real last expression. So the cap was enforced only by the view
  # that hides the registration link; requesting the URL directly registered
  # past it.
  def can_request?
    self.requested_teams_number < self.max_team_number
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

  # Split out of missing_translations so a locale that is not declared yet can
  # still produce a work-list: the AI translation feature translates first and
  # declares second, and the publish gate then passes. missing_translations
  # keeps its exact former behaviour, expressed in terms of this.
  def missing_translated_fields_in(locale)
    translatable_records.flat_map do |record|
      record.class::TRANSLATABLE_FIELDS.map do |field|
        next if record.translated?(field, locale)

        MissingTranslation.new(record, field, locale, label_for(record, field))
      end.compact
    end
  end

  def missing_translations
    non_primary = self.available_locale_list - [ self.primary_locale.to_s ]
    return [] if non_primary.empty?

    non_primary.flat_map { |locale| missing_translated_fields_in(locale) }
  end

  # Public because the AI-translation review screen renders it from a view: a
  # proposal needs a human-readable name for the field it translates ("Level 3,
  # task text"), and this already computes exactly that. Deliberately not
  # snapshotted onto translation_proposals -- the label is derived from
  # position and field name, so it should render in the READER's locale, not in
  # whichever locale the run happened to start in.
  def label_for(record, field)
    field_name = I18n.t("games.translations.fields.#{field}")
    case record
    when Game     then I18n.t("games.translations.game_field",  :field => field_name)
    when Level    then I18n.t("games.translations.level_field", :position => record.position, :field => field_name)
    when Hint     then I18n.t("games.translations.hint_field",  :position => record.level&.position,
                                                                :minutes => record.delay_in_minutes)
    when Question then I18n.t("games.translations.question_field", :position => record.level&.position)
    # Without a branch here the case returns nil, putting a blank entry in the
    # author's to-do list -- an instruction to translate something unnamed.
    when Option   then I18n.t("games.translations.option_field",
                              :position => record.question&.level&.position,
                              :text => record.text)
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

  # Drafts are exempt, for the reason #started? already gives twenty lines
  # above: "the start date on an unpublished game is a plan, not an event."
  # A draft ages past its own start date with no action from anyone, so that
  # state is reachable and tolerated either way -- this validation only ever
  # stopped an author reaching it DELIBERATELY, while the clock reached it
  # for them.
  #
  # Publication is still gated. `draft?` reads the value being saved, so a
  # game going from draft to published (visibility "draft" -> "listed") is not
  # a draft by the time this runs, and a past start date is refused there --
  # which is the moment that matters, and the same moment
  # declared_locales_are_translated_before_publication guards.
  #
  # Reported from production 2026-08-13: an author could not leave test mode.
  # start_test parks the real start in test_date and sets starts_at to now;
  # finish_test swaps them back AND clears author_finished_at, the only other
  # thing suppressing this check -- so once the parked date had passed, the
  # save was refused and the game was stuck in testing permanently. The
  # parked date sits still while the clock moves, so the longer the test ran
  # the likelier it got, and test_date is in no permitted-params list, so
  # nothing the author could type would fix it. finish_test sets visibility
  # back to "draft" first, which is what makes this exemption cover it.
  def game_starts_in_the_future
    return if self.draft?

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
  # Exempt for drafts on the same reading as game_starts_in_the_future above:
  # an unpublished game's registration deadline is a plan too, it ages past
  # on its own, and publication still refuses a stale one.
  #
  # Not reachable through finish_test, which never restores a deadline
  # (start_test nils it and finish_test leaves it nil) -- included because
  # splitting the pair would leave an author able to save a draft whose start
  # has slipped but not one whose deadline has, which is a distinction with
  # no reason behind it.
  # Both deadline rules stand down during a test run, and that exemption is
  # what lets the author's deadline survive one.
  #
  # start_test moves starts_at to Time.now, so a deadline set for any future
  # date is then "after the game starts" and a deadline already past is "in the
  # past" -- during a test EVERY non-nil deadline is invalid, and start_test
  # could not save at all. It used to buy the save by blanking the column,
  # which worked and destroyed the value: unlike starts_at, stashed in
  # test_date and restored by finish_test, the deadline was never brought back.
  # An author who rehearsed their game silently lost the cutoff they had set,
  # and because shared/_game_entry_controls.html.erb needs a NON-NIL deadline
  # to report registration closed, registration then never closed.
  #
  # Skipping is safe rather than merely convenient: a testing game is started
  # (start_test sets visibility to "listed" and moves starts_at into the
  # past), and ensure_game_was_not_started already covers edit and update, so
  # an author cannot reach these validations mid-test to write a nonsensical
  # deadline. The only writers during a test are start_test and finish_test
  # themselves.
  #
  # finish_test restores starts_at before clearing is_testing, so the rules
  # apply again on the very save that ends the test -- a deadline that has
  # since fallen into the past is reported then, which is correct: it really
  # has passed, and losing it silently was the worse answer.
  def deadline_is_in_future
    return if self.draft?
    return if self.is_testing?

    if self.author_finished_at.nil? and self.registration_deadline and self.registration_deadline < Time.now
        self.errors.add(:registration_deadline, :in_the_past)
    end
  end
  def deadline_is_before_game_start
    return if self.is_testing?

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
  #   - a game created already published (the author unchecked the draft box
  #     at creation, publishing the game immediately)
  #   - a draft being published
  #   - a locale added to a game that is already live
  def declared_locales_are_translated_before_publication
    return if self.draft?
    return unless self.new_record? ||
                  self.visibility_changed?(:from => "draft", :to => "listed") ||
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
                         :questions => [ :content_translations,
                                         { :options => :content_translations } ]).each do |level|
      records << level
      records.concat(level.hints)
      level.questions.each do |question|
        records << question
        records.concat(question.options)
      end
    end
    records
  end
end
