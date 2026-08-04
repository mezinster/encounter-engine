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

When /иду по ссылке "(.*)"$/ do |link|
  click_link(link)
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
