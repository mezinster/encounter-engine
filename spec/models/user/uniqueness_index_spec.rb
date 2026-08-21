require "rails_helper"

# `users` carried NO unique index on either column -- uniqueness was a model
# validation and nothing else. That is a check-then-insert with a gap in the
# middle: two concurrent signups both pass `validates :uniqueness`, both
# insert, and the account that loses is unreachable afterwards, because every
# lookup in the app is a `find_by` that returns exactly one row. The welcome
# letter for the other one carries a password that will never work.
#
# Reported as the ordinary, non-racing half of the same problem: a
# double-pressed "Register" showed "this nickname is taken" while the account
# had in fact been created. The button is now disabled on submit
# (public/javascripts/submit_once.js), but that is JavaScript, invisible to
# both suites and absent for anyone who blocks it -- so the index is the half
# that actually holds.
#
# Asserted by INSERTING PAST THE VALIDATIONS, which is the only way to tell
# the two mechanisms apart: with the validation alone these raise
# RecordInvalid, and with the index they raise RecordNotUnique.
describe User, "database-level uniqueness" do
  it "refuses a duplicate e-mail at the database" do
    first = create_user

    expect {
      User.connection.execute(
        "INSERT INTO users (email, nickname, created_at, updated_at) " \
        "VALUES (#{User.connection.quote(first.email)}, 'other#{rand(10_000)}', " \
        "#{User.connection.quote(Time.now)}, #{User.connection.quote(Time.now)})"
      )
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "refuses a duplicate nickname at the database" do
    first = create_user

    expect {
      User.connection.execute(
        "INSERT INTO users (email, nickname, created_at, updated_at) " \
        "VALUES ('other#{rand(10_000)}@mail.ru', #{User.connection.quote(first.nickname)}, " \
        "#{User.connection.quote(Time.now)}, #{User.connection.quote(Time.now)})"
      )
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
