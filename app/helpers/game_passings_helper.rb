# -*- encoding : utf-8 -*-
module GamePassingsHelper
  def answer_posted?
    ! @answer.nil?
  end

  def answer_was_correct?
    !! @answer_was_correct
  end

  # The level a correct answer took the team OFF, or nil when the team is
  # still on the level it answered (GamePassingsController#note_level_passed).
  # Non-nil is exactly the case where the message on screen describes a
  # question the page no longer shows.
  def level_passed
    @level_passed
  end

  # "Код" or "Ответ", picked from how the answer was actually submitted --
  # a quiz level sends option ids and #post_options joins the chosen option
  # TEXTS into @answer, so reporting those through the code message called a
  # pressed radio button a код. :code is the fallback for any path that did
  # not say, which keeps the wording the frozen features assert.
  def answer_feedback_message
    prefix = @answer_kind == :choice ? "choice" : "answer"
    suffix = answer_was_correct? ? "correct" : "incorrect"

    t("game_passings.show_current_level.#{prefix}_#{suffix}", :answer => @answer)
  end

  # Set only by GamePassingsController#reject_empty_answer, mutually
  # exclusive with answer_posted? -- a rejected submission never sets
  # @answer, so the two branches in show_current_level.html.erb never both
  # fire.
  def answer_rejected?
    @answer_rejected.present?
  end

  # @answer_rejected is one of the two kinds reject_empty_answer is called
  # with: :choice (post_options) or :code (post_answer). Building the key
  # this way keeps the two messages next to each other in the locale files
  # rather than needing a case statement here for what is otherwise the same
  # lookup.
  def rejected_answer_message
    t("game_passings.show_current_level.answer_missing_#{@answer_rejected}")
  end

  # show_results is guest-reachable (GamePassingsController#show_results has
  # no require_authentication! before_action -- see game_passings_controller.rb:9),
  # unlike LogsController#show_full_log which the link points to. Without this
  # gate, a guest or a team still mid-game would see a "Лог ответов" link that
  # 401s when clicked, since app/controllers/logs_controller.rb's
  # ensure_full_log_access only admits the game's author or a player whose
  # team genuinely finished (finished? && !exited?, see task-S-report.md for
  # why the exited? check exists). Mirrors that rule exactly so the link is
  # visible if and only if following it would succeed. Both real scenarios
  # that reach this link are honoured: features/logs/log.feature:113
  # ("Игрок заканчивает игру и получает доступ к полному логу") and
  # features/games/game_full_log.feature:20 both reach show_results by
  # actually completing the game, so a finished non-exited player always
  # sees this link. current_user may be nil here (guest), unlike in the
  # controller method where require_authentication! already ran.
  # Gated resolution goes through GamePassing.gated_attempt_for -- THE single
  # definition of "this team's current attempt" (finding 3 of the
  # whole-branch review). Finding 6: this used to resolve through
  # game.current_run.passing_for even for a gated game, which is scoped by
  # game_run_id and can never see a runless attempt, so the link was false
  # for every gated attempt -- reachable only by typing show_full_log's URL
  # directly, which LogsController#ensure_full_log_access (see its own
  # gated_passing_for) already admitted.
  def full_log_visible?(game)
    return false unless logged_in?
    return true if game.created_by?(current_user)

    game_passing = current_user.team &&
      (game.pass_required? ? GamePassing.gated_attempt_for(game, current_user.team) :
                             game.current_run.passing_for(current_user.team))
    !!(game_passing&.finished? && !game_passing.exited?)
  end
end
