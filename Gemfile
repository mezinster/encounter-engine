source "https://rubygems.org"

ruby "3.3.12"

gem "rails", "8.0.5.1"
gem "sqlite3", "~> 2.0", group: [:development, :test]
gem "pg", group: :production
gem "puma"
gem "acts_as_list"

group :development, :test do
  gem "rspec-rails", "~> 7.0"
  gem "pry"
  gem "pry-byebug"
end

group :test do
  gem "cucumber-rails", require: false
  gem "capybara"
end
