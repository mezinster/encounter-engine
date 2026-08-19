require "rails_helper"

# Why this exists, given spec/i18n_spec.rb already checks a great deal:
#
# That file proves a locale is a structurally valid SUBSET of ru -- no orphan
# keys, no typo'd paths, matching interpolation variables. It does not prove
# any particular key is PRESENT. A locale file carrying nothing but its seven
# locales.* endonyms passes every check in it.
#
# That is correct while a language is in progress and wrong once it has
# shipped, because the failure is invisible rather than loud:
# config.i18n.fallbacks ([:ru]) means an incomplete Turkish play screen
# renders in RUSSIAN, mid-game, to a player who chose Turkish precisely
# because they do not read Russian. Nothing raises. Nothing is blank. The team
# just loses time reading a language they did not ask for.
#
# So this spec reads the YAML FILES directly rather than asking I18n -- going
# through the backend would resolve the fallback and assert nothing.
describe "the play screen in every shipped locale" do
  # Locales that have been declared complete. A language still in progress is
  # deliberately absent: fallbacks make a partial file safe, and this list is
  # what says "this one is finished". Adding to it is the LAST step of
  # shipping a language, in the same PR that translates it -- never the first.
  SHIPPED_LOCALES = %i[ru en uk ka be pl tr].freeze

  # The strings a team reads mid-game, under time pressure, with a clock
  # running. A fallback here is not cosmetic in the way a wrong menu label is:
  # getting the exit button or the answer feedback wrong costs someone the
  # game.
  #
  # errors.passing_stopped_by_operator is not a game_passings.* key but meets
  # the same test: it is rendered as the WHOLE response to a team whose run the
  # operator closed, in place of their level.
  PLAY_SCREEN_KEYS = %w[
    game_passings.show_current_level.title_prefix
    game_passings.show_current_level.level_label
    game_passings.show_current_level.answer_label
    game_passings.show_current_level.submit
    game_passings.show_current_level.exit_game
    game_passings.show_current_level.answer_correct
    game_passings.show_current_level.answer_incorrect
    game_passings.show_current_level.choice_correct
    game_passings.show_current_level.choice_incorrect
    game_passings.show_current_level.level_passed
    game_passings.show_current_level.answer_missing_choice
    game_passings.show_current_level.answer_missing_code
    game_passings.show_current_level.hint_label
    game_passings.show_current_level.choose
    game_passings.show_current_level.attachments_label
    game_passings.show_current_level.skip_level
    game_passings.confirm_skip.title
    game_passings.confirm_skip.cost
    game_passings.confirm_skip.cost_time_only
    game_passings.confirm_skip.remaining
    game_passings.confirm_skip.confirm
    game_passings.confirm_skip.cancel
    game_passings.withdrawn.title
    errors.passing_stopped_by_operator
    errors.access_revoked
    game_passings.pass_revoked.what_to_do
  ].freeze

  SHIPPED_LOCALES.each do |locale|
    it "defines every play-screen string in #{locale}, without falling back" do
      data = YAML.load_file(Rails.root.join("config/locales/#{locale}.yml")).fetch(locale.to_s)

      PLAY_SCREEN_KEYS.each do |key|
        value = key.split(".").reduce(data) { |node, part| node.is_a?(Hash) ? node[part] : nil }
        expect(value).to be_present,
          "#{locale}.yml does not define #{key} -- it would fall back to Russian mid-game"
      end
    end
  end

  # The list above is only as good as its membership. If a locale is
  # registered and complete but nobody remembered to add it here, this spec
  # silently stops covering it -- the exact failure it was written to prevent,
  # one level up.
  it "covers every registered locale, or names the ones it deliberately skips" do
    in_progress = I18n.available_locales - SHIPPED_LOCALES

    expect(in_progress).to eq([]),
      "these locales are registered but not on SHIPPED_LOCALES: #{in_progress.inspect}. " \
      "If one is still being translated that is correct -- add it to this message. " \
      "If it has shipped, add it to SHIPPED_LOCALES."
  end
end
