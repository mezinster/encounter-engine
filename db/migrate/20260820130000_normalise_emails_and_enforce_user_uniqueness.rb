# Canonicalises every stored address, then makes the database enforce what
# User has only ever claimed.
#
# Both halves answer production reports from 2026-08-20:
#
#   * addresses stored capitalised (iPhone auto-capitalisation in the signup
#     form's plain text input) locked players out, because every lookup is an
#     exact match -- see User#normalise_email for the whole story;
#   * a double-pressed "Register" showed "this nickname is taken" while the
#     account had in fact been created. `users` carried no unique index on
#     either column, so uniqueness was a check-then-insert with a gap in the
#     middle: two concurrent signups both validate, both insert, and the
#     losing account is unreachable for ever afterwards.
#
# The backfill was already applied by hand to production on 2026-08-20 (13
# users, 2 mixed-case, 0 collisions) so the two affected players could log in
# the same day. It is repeated here because it must also run on every other
# instance, and because a migration that assumes someone ran a one-off SQL
# statement is a migration that breaks the next fresh deploy.
class NormaliseEmailsAndEnforceUserUniqueness < ActiveRecord::Migration[8.0]
  def up
    # Downcase and trim in one statement rather than loading records: the
    # model's before_validation is not available to a migration (and running
    # a model callback from one is how a migration starts failing months
    # later, when the model has moved on).
    execute <<~SQL
      UPDATE users SET email = LOWER(TRIM(email)) WHERE email <> LOWER(TRIM(email))
    SQL

    # RAISE, never merge. If two accounts differ only in case, one of them
    # belongs to a real person who will lose access the moment we pick a
    # winner -- so the deploy stops and a human decides, rather than this
    # migration guessing. Checked explicitly instead of letting add_index
    # fail, because "index already exists / duplicate key" says nothing about
    # which rows are the problem or what to do next.
    %w[email nickname].each do |column|
      duplicates = select_values(<<~SQL)
        SELECT LOWER(TRIM(#{column})) FROM users
        GROUP BY LOWER(TRIM(#{column})) HAVING COUNT(*) > 1
      SQL

      next if duplicates.empty?

      raise <<~MESSAGE
        Cannot add a unique index on users.#{column}: #{duplicates.size} value(s) are held by more than one account.
        Resolve them by hand -- decide which account keeps the #{column} and what happens to the other --
        then re-run this migration. Merging them automatically would silently take an account away from someone.
      MESSAGE
    end

    # Plain unique indexes, not functional ones on LOWER(...). The data is
    # canonical by the time a row is written (User#normalise_email), so these
    # are equivalent for e-mail, and they dump identically into schema.rb for
    # both adapters this repo uses -- sqlite in development and test,
    # PostgreSQL in production. A LOWER() index would be the stronger
    # guarantee and the more fragile artefact.
    #
    # nickname keeps its case-SENSITIVE semantics, matching the validation it
    # has always had. Making nicknames case-insensitive is a product decision
    # about display names, not part of fixing a signup race, and it would
    # retroactively invalidate names players already hold.
    add_index :users, :email,    unique: true
    add_index :users, :nickname, unique: true
  end

  def down
    remove_index :users, :email
    remove_index :users, :nickname
    # The backfill is deliberately NOT reversed: the original spellings are
    # not recoverable from the downcased value, and a rollback that invented
    # them would be worse than one that leaves canonical data in place.
    # Production's pre-change values are on the host at
    # ~/email_backfill_before_20260820.csv.
  end
end
