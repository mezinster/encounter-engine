# Deep-copies a real game's CONTENT into a throwaway one, so a load test can be
# seeded without authoring thirty levels by hand -- and so it loads the box with
# level text and code counts that actually exist.
#
# Deliberately not a Game instance method. This is a load-testing concern; as
# `Game#duplicate` it would become a general-purpose feature by accident, and
# would then need to answer questions about files, permissions and history that
# only have answers in this narrow context.
module LoadTest
  class GameCloner
    # Content, not history. Everything absent from this list is absent on
    # purpose: logs, entries, passings, access passes and codes, point
    # transactions and translation runs all belong to the game that was really
    # played. game_files is excluded too -- see the design, section 4.2.1: a
    # cloned level referencing a file renders that reference broken, which is
    # accepted rather than fixed, because copying blobs to a host with ~1.1 GB
    # spare buys marginal page weight on a CPU-bound test.
    #
    # available_locales, access_mode and points_enabled are deliberately
    # absent too, even though the source game carries values for all three --
    # #call below sets each explicitly instead of copying it. See the
    # comments there.
    #
    # This is the third attribute pulled out of this list for exactly this
    # reason (available_locales and access_mode were the first two, both
    # fixing production 422s). The pattern: an attribute the design
    # *specifies* a value for must be set explicitly here, never copied from
    # the source -- copying silently reintroduces whatever the source
    # happened to have, which is a different bug every time depending on
    # which game gets cloned.
    GAME_ATTRIBUTES = %w[
      description primary_locale visibility
      level_completion_points game_completion_points
      max_skips skip_points_fine skip_time_penalty
    ].freeze

    LEVEL_ATTRIBUTES = %w[
      text name position wrong_answer_penalty any_code_passes points_award
    ].freeze

    def initialize(source)
      @source = source
    end

    def call(name:, author:)
      clone = nil
      Game.transaction do
        clone = Game.new(@source.attributes.slice(*GAME_ATTRIBUTES))
        clone.name   = name
        clone.author = author
        # available_locales is NOT copied from the source. copy_level below
        # copies each level's own-language text but never touches
        # content_translations, so a clone that declared the source's full
        # available_locales would announce languages it has zero translated
        # fields for -- Game's completeness validation
        # (available_locales_are_known and friends, plus the
        # missing_translations check behind them) then refuses to save it.
        # That is exactly the production 422: "Игра объявляет языки, на
        # которые переведено не всё". The load test drives one locale and
        # never switches, so translations carry no measurement value here --
        # copying them would be real work (content_translations rows per
        # level/hint/question/option) for a case nothing exercises. Declaring
        # only the clone's own primary_locale (already copied via
        # GAME_ATTRIBUTES) keeps it complete by construction.
        clone.available_locales = clone.primary_locale
        # access_mode is likewise NOT copied. The design
        # (docs/superpowers/specs/2026-08-21-load-testing-design.md, section
        # 4.1) requires the seeded game be access_mode: "scheduled" --
        # GamePassingsController only offers the play path it needs. A
        # "pass_required" source (or any other mode) would clone a gated
        # game that the load test's own teams cannot get past: every seeded
        # team hits the no_access_pass branch instead of playing, which
        # defeats the point of seeding them. Forced here rather than left to
        # whatever the source happens to be.
        clone.access_mode = "scheduled"
        # points_enabled is likewise NOT copied. The design
        # (docs/superpowers/specs/2026-08-21-load-testing-design.md, section
        # 4.1) requires the seeded game have points_enabled: true --
        # point_transactions writes are part of the real cost of an accepted
        # answer, and testing with points off measures a cheaper app than we
        # run. A source game with points off would silently clone a cheaper
        # test than the design calls for; forced here rather than left to
        # whatever the source happens to have.
        clone.points_enabled = true
        # max_team_number lives on the run, not on GAME_ATTRIBUTES, but Game
        # itself validates it unconditionally (games.rb, `validates
        # :max_team_number, numericality: ...`, no `on:` and no `allow_nil`)
        # -- unlike the run's OWN copy of that check, which is scoped to
        # `on: :open` and would not fire here. The autobuilt run behind a bare
        # `Game.new` carries no max_team_number, so leaving it unset fails
        # that validation on every clone. Copying the source's value keeps
        # the clone saveable without reaching into GameRun's scheduling
        # concerns for anything else.
        clone.max_team_number = @source.max_team_number
        clone.save!
        @source.levels.order(:position).each { |level| copy_level(level, clone) }
      end
      clone.reload
    end

    private

    def copy_level(level, clone)
      copied = Level.new(level.attributes.slice(*LEVEL_ATTRIBUTES))
      copied.game = clone
      copied.save!

      # Questions first: answers carry question_id, so the mapping has to exist
      # before the answers are written or every code is orphaned.
      question_map = level.questions.each_with_object({}) do |question, map|
        map[question.id] = Question.create!(:level => copied,
                                            :questions => question.questions).id
      end

      level.answers.each do |answer|
        Answer.create!(:level_id    => copied.id,
                       :question_id => question_map[answer.question_id],
                       :value       => answer.value)
      end

      level.hints.each do |hint|
        Hint.create!(:level => copied, :text => hint.text, :delay => hint.delay)
      end
    end
  end
end
