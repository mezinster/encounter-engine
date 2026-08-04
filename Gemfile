source "https://rubygems.org"

ruby "3.3.12"

gem "rails", "8.0.5.1"
gem "sqlite3", "~> 2.0", group: [:development, :test]
gem "pg", group: :production
gem "puma"
gem "acts_as_list"

# Question#matches_any_answer (via lib/ee_strings.rb) still depends on this
# for case-insensitive Cyrillic comparison. Task 5 replaces it with native
# String#upcase and drops this gem along with lib/ee_strings.rb.
gem "unicode_utils"

group :development, :test do
  gem "rspec-rails", "~> 7.0"
  gem "pry"
  gem "pry-byebug"
end

group :test do
  gem "cucumber-rails", require: false
  gem "capybara"
end
