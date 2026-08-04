# -*- encoding : utf-8 -*-
#
# These used to stub Time.now with rspec-mocks, which left Date.today and
# Time.zone.now on the real clock. ActiveSupport::Testing::TimeHelpers moves
# all three -- and the app reads all three: hints unlock on a delay measured
# from the level entry time, and levels record entry times through
# ActiveRecord (Time.zone).
#
# The World gets travel_to/travel_back from features/support/env.rb, which also
# registers the After hook that unwinds the travel.

Given %r{сейчас "(.*)"} do |fake_datetime|
  # The Merb version did Time.parse("#{fake_datetime} UTC"), i.e. "read a
  # bare timestamp as UTC". Time.zone is UTC in this app, so Time.zone.parse
  # of a bare timestamp is the same thing -- and, unlike appending " UTC" to
  # a string, it does the right thing for the values these steps feed back to
  # themselves below, which carry an explicit offset.
  travel_to Time.zone.parse(fake_datetime)
end

Given /прошла 1 секунда/ do
  step %{сейчас "#{Time.now + 1}"}
end

Given /прошло (\d+) минут.{0,1}/ do |minutes|
  step %{сейчас "#{Time.now + minutes.to_i * 60}"}
end
