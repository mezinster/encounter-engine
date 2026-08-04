source "https://rubygems.org"

ruby "3.3.12"

gem "rails", "8.0.5.1"
# No group restriction: the production image's CI smoke test (Dockerfile +
# .github/workflows/images.yml) boots with a sqlite3:// DATABASE_URL to avoid
# needing a Postgres service container, and config/database.yml's `url:`
# resolves the adapter from that URL's scheme -- so the sqlite3 gem must be
# loadable even inside the production bundle (`bundle ... without
# 'development test'`). Real production still connects via a postgresql://
# DATABASE_URL, so this does not change which database production talks to.
gem "sqlite3", "~> 2.0"
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
