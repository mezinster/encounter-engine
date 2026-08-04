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
  gem "kamal", "~> 2.0", require: false
end

group :test do
  gem "cucumber-rails", require: false
  gem "capybara"
  # Restores the bare `assigns(:x)` helper controller specs relied on before
  # Rails 5 split it out. Four ported specs need it for @answer/
  # @answer_was_correct etc. -- there's no equivalent way to read those
  # without it.
  gem "rails-controller-testing", "~> 1.0"
end
