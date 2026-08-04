# -*- encoding : utf-8 -*-
# Commonly used navigation and form steps. Was Webrat; now Capybara on the
# rack_test driver. The API maps one-to-one, so the step regexes -- which the
# feature files match against character for character -- are untouched.

When /захожу по адресу (.*)$/ do |path|
  visit path
end

When /нажимаю "(.*)"$/ do |button|
  click_button(button)
end

# first(:link, …).click rather than click_link, and rather than a global
# Capybara.match = :first.
#
# Webrat resolved an ambiguous locator by picking a match; Capybara's default
# :smart raises Capybara::Ambiguous. Running the suite under :smart finds
# exactly two ambiguities, both LINKS, and both same-href duplications that
# exist verbatim in the Merb layouts: "Создать команду" (left-menu partial +
# dashboard body, 137 scenarios) and "Личный кабинет" (header + left menu, 2).
# Since both duplicates point at the same URL, picking the first is what Webrat
# did and masks nothing.
#
# Scoping the tolerance here keeps buttons and form fields strict: a global
# Capybara.match = :first would also make click_button and fill_in silently
# pick among genuinely different targets.
When /иду по ссылке "(.*)"$/ do |link|
  first(:link, link).click
end

When /ввожу "(.*)" в поле "(.*)"$/ do |value, field|
  fill_in(field, :with => value)
end

When /отмечаю галочку "(.*)"$/ do |field|
  check(field)
end

When /снимаю галочку "(.*)"$/ do |field|
  uncheck(field)
end

When /^I select "(.*)" from "(.*)"$/ do |value, field|
  select(value, :from => field)
end

When /^I uncheck "(.*)"$/ do |field|
  uncheck(field)
end

When /^I choose "(.*)"$/ do |field|
  choose(field)
end

When /^I attach the file at "(.*)" to "(.*)" $/ do |path, field|
  attach_file(field, path)
end

Then /^show me the page$/ do
  save_and_open_page
end

Then /^дайте мне отладчик$/ do
  require 'pry'
  binding.pry
end
