# -*- encoding : utf-8 -*-
#
# Every assertion in this file used to run against `webrat_session.response.body`
# -- the raw HTML. That is no longer safe: Rails escapes the output of `t()` and
# `link_to` where Merb did not, so a quote in the UI copy reaches the body as
# `&quot;`, an apostrophe as `&#39;` and an ampersand as `&amp;`. Asserting
# against the raw body would make any expectation containing one of those
# characters wrong -- silently *passing* in the negative case. These now go
# through Capybara's DOM text/selector matchers, which see the parsed document
# and therefore the characters the user actually reads.

Then /должен увидеть сообщение "(.*)"$/ do |text|
  step %{должен увидеть "#{text}"}
end


# `:all` (rather than Capybara's default, visible text only) is deliberate and
# is what keeps this a translation of the old assertion rather than a new,
# stricter one. Webrat matched the raw HTML, which reaches text that is in the
# document but not painted -- and three scenarios depend on exactly that:
# features/games/enter-game-before-start.feature:23,42 assert "До начала
# осталось" and the whole year/month/day plural table, and
# features/games/registration-to-game.feature:94 asserts "You are not
# registered"; all of those live inside the inline <script> of
# app/views/shared/_countdown.html.erb, which visible text excludes.
# `:all` keeps webrat's reach while still reading the *parsed* document, so
# `&#39;` is an apostrophe again -- which is the whole point of moving off the
# raw body. Positive assertions cannot go vacuous by widening, and the negative
# form below is if anything stricter with `:all` than with visible-only.
Then /должен увидеть "(.*)"$/ do |text|
  expect(page).to have_text(:all, text)
end

Then /должен увидеть \/(.*)\/$/ do |regex|
  expect(page).to have_text(:all, /#{regex}/m)
end

Then /должен увидеть следующее:/ do |strings_table|
  strings = strings_table.raw.map(&:first)
  strings.each do |string|
    step %{должен увидеть "#{string}"}
  end
end

Then /не должен видеть следующее:/ do |strings_table|
  strings = strings_table.raw.map(&:first)
  strings.each do |string|
    step %{не должен видеть "#{string}"}
  end
end

Then /должен увидеть ссылку на (.*)$/ do |url|
  expect(page).to have_link(href: url)
end

Then /не должен видеть ссылку на (.*)$/ do |url|
  expect(page).to have_no_link(href: url)
end

# have_button covers both shapes -- <input type="submit" value="..."> (what
# have_tag("input", type: "submit", value: text) used to look for) and
# <button>...</button>.
Then /должен увидеть кнопку "(.*)"$/ do |text|
  expect(page).to have_button(text)
end

Then /должен быть перенаправлен по адресу (.*)/ do |url|
  # Still a no-op, as it was in the Merb suite, where the entire body was the
  # comment "# WTF?!". Capybara does know where the browser ended up, so this
  # CAN assert what its name claims --
  #
  #     expect(page.current_path).to eq(url.strip)
  #
  # -- and that was tried. It is left off because two scenarios cannot satisfy
  # it as written, and the .feature files are the read-only contract:
  #
  #   features/games/enter-game-before-start.feature:31,50 assert, three lines
  #   apart, both "должен быть перенаправлен в профиль игры" (/games/1) and
  #   "должен быть перенаправлен по адресу /play/". The second describes what
  #   the countdown's JS finish() handler does when the clock runs out
  #   (app/views/shared/_countdown.html.erb:46) -- which a rack_test run never
  #   executes. The two assertions are mutually exclusive without JavaScript.
  #
  # Turning it on also flags features/games/test-game-1.feature:57,70,82, which
  # say "/play/" for a path that is and always was "/play/<game id>". Both are
  # scenario-text defects rather than porting defects; see the task report for
  # the full findings and the patch to enable the assertion.
end

# THE VACUOUS ASSERTION. This was
#
#     webrat_session.response.body.to_s.should_not =~ /#{text}/m
#
# i.e. a *regex* match against the raw HTML. features/games/one-language-code
# .feature:24,30,36,42 and its -russian twin assert
# `не должен видеть "Код неверный, вы ввели 'Code1'"` -- and Rails renders that
# apostrophe as `&#39;`, so the literal `'Code1'` never appears in the body and
# `should_not` passed no matter what the page said. Eight scenarios were
# testing nothing.
#
# have_no_text(:all, ...) matches the PARSED document's text, where the entity
# is an apostrophe again, and treats the argument as a literal string rather
# than a regex -- which is what "не должен видеть" means.
#
# Proved both ways by temporarily prepending
#   <p><%= "Код неверный, вы ввели 'Code1'" %></p>
# to app/views/game_passings/show_results.html.erb and running
# features/games/one-language-code.feature:20 -- raw body then contains
# `&#39;Code1&#39;`:
#   old raw-body step  -> "1 scenario (1 passed), 12 steps (12 passed)"
#   this step          -> "1 scenario (1 failed)", expected not to find text
#                         "Код неверный, вы ввели 'Code1'" in ...
Then /не должен видеть "(.*)"$/ do |text|
  expect(page).to have_no_text(:all, text)
end
