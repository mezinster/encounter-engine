# -*- encoding : utf-8 -*-
#
# Steps for features/i18n/switch-language.feature. Written in English
# (Cucumber Expressions, {string}) to match that feature's language, but they
# delegate to the existing Russian step vocabulary wherever an equivalent
# already exists -- registering, logging in, creating a game -- rather than
# re-implementing that machinery. Only what's genuinely new to this task is
# new here: visiting a page with an explicit ?locale= override, and driving
# the language field this task adds to the profile form.
#
# Cucumber matches Given/When/Then steps from a single pooled registry
# regardless of which keyword originally defined them (see e.g.
# features/authentication/steps/login_steps.rb, which `step`s into a When
# from inside a Given) -- the keyword above a step definition is documentation,
# not a constraint on how it may be invoked.

Given('a user {string} is registered') do |nickname|
  # "зарегистрирован как" (features/authentication/steps/login_steps.rb)
  # leaves the new user logged in; log back out so a scenario that wants an
  # anonymous visitor (e.g. "A visitor switches the interface to English")
  # gets one, and a scenario that wants to be signed in asks for that
  # explicitly via "I am logged in as".
  step %{я зарегистрирован как #{nickname}}
  step %{я разлогиниваюсь}
end

Given('I am logged in as {string}') do |nickname|
  step %{я логинюсь как #{nickname}}
end

Given('a game {string} was created by {string}') do |game_name, author_nickname|
  # Not "пользователем X создана игра Y" -- that step re-registers the
  # author from scratch (features/games/steps/games_steps.rb:8-11), which
  # would collide with this feature's Background having already registered
  # "Iv". "X создаёт игру Y" just logs the (already-registered) author in and
  # drives the new-game form, which is exactly what's needed here.
  step %{#{author_nickname} создаёт игру "#{game_name}"}
end

When('I go to the front page') do
  visit root_path
end

When('I go to the front page with locale {string}') do |locale|
  visit root_path(locale: locale)
end

# Exercises the actual switcher markup (app/views/layouts/_header.html.erb),
# as opposed to the "with locale" steps above, which build the target URL
# directly and never touch the partial's own link-generation code at all.
When('I click the {string} language switcher link') do |label|
  within("#locale-switcher") { click_link(label) }
end

When('I go to the games list with locale {string}') do |locale|
  # Not the front page: app/views/index/index.html.erb (the "front page") is
  # just a title and a link to the games list -- it never renders a game's
  # name. The games list (games#index, app/views/games/_list.html.erb) is
  # where a game's name is actually on the page, which is what the "game
  # content is not translated" scenario needs to inspect.
  visit games_path(locale: locale)
end

When('I go to the dashboard') do
  visit dashboard_path
end

When('I set my interface language to {string}') do |locale|
  # Reaches the profile edit form the same way a player would: the "Профиль"
  # link (users#index) then "Редактировать профиль..." (users#edit) --
  # exactly the path features/games/steps/games_steps.rb's "данные
  # пользователя ... такие" steps already use. Both link texts and the
  # locale field's own label/options are read via I18n.t with an explicit
  # `locale: :ru` because this step runs before the preference it's setting
  # takes effect: the page it's currently on is still rendered in the
  # scenario's starting locale (:ru, pinned by features/support/env.rb),
  # regardless of which locale `locale` names.
  step %{иду по ссылке "Профиль"}
  step %{иду по ссылке "Редактировать профиль..."}
  select I18n.t("locales.#{locale}", locale: :ru),
    from: I18n.t("users.edit.locale_label", locale: :ru)
  click_button I18n.t("users.edit.submit", locale: :ru)
end

Then('I should see {string}') do |text|
  step %{должен увидеть "#{text}"}
end
