# -*- encoding : utf-8 -*-
require "rails_helper"

# Golden-vector regression test for Task 6 (Authentication).
#
# The two (salt, crypted_password) pairs below were captured from a database
# written by the REAL Merb app (merb-auth's SaltedUser mixin), not derived
# from this codebase. Both rows were created through the running app with
# the password "demo1234" -- see
# .superpowers/sdd/2026-08-04-merb-to-rails-i18n/task-6-password-vectors.txt.
#
# If User.encrypt/#authenticate ever drift from
#   Digest::SHA1.hexdigest("--" + salt + "--" + password + "--")
# these examples fail, which is exactly the signal that every existing
# user's password has silently stopped verifying -- the single highest-risk
# regression this migration can introduce, since a broken hash produces no
# error, just a login form that rejects a correct password.
#
# Both accounts happen to share one salt: merb-auth derived the salt from
# Time.now.to_s (one-second resolution) and the constant login_param
# (:email), so any two accounts created within the same second and the same
# password collide. That collision is itself evidence this is genuine
# merb-auth output, not a hand-rolled fixture -- see the RULING in the
# vectors file for why Task 6 replaces salt generation for NEW users with
# SecureRandom.hex(20) while leaving `encrypt` itself untouched.
describe User, "authenticating against merb-auth-produced hashes" do
  # A plain local variable, not a top-level constant: `GOLDEN_VECTORS = [...]`
  # written directly inside a `describe` block is evaluated in a context
  # that lands it on Object, making it a global constant reachable (and
  # collidable) from any other spec file in the suite. `it` blocks are
  # closures, so they still see this local across the whole describe block
  # without needing a constant.
  golden_vectors = [
    {
      email: "author@example.com",
      salt: "06e9ffff5b950eb0733ee392e3a991cdd04e88e2",
      crypted_password: "5c191e1b30b0a410a4088a5b1c20334ab190f2e1"
    },
    {
      email: "player@example.com",
      salt: "06e9ffff5b950eb0733ee392e3a991cdd04e88e2",
      crypted_password: "5c191e1b30b0a410a4088a5b1c20334ab190f2e1"
    }
  ].freeze

  golden_vectors.each do |vector|
    it "verifies the real merb-auth hash captured for #{vector[:email]}" do
      User.encrypt("demo1234", vector[:salt]).should == vector[:crypted_password]
    end
  end

  it "authenticates a User whose crypted_password/salt come straight from the Merb database, without re-hashing them" do
    user = User.new(
      nickname: "golden#{random_string}",
      email: "golden#{random_string}@diesel.kg"
    )
    user.salt = golden_vectors.first[:salt]
    user.crypted_password = golden_vectors.first[:crypted_password]
    user.save!(validate: false)

    user.authenticate("demo1234").should be_truthy
    user.authenticate("wrong-password").should be_falsey
  end

  it "fails closed when salt is blank, rather than hashing against an empty salt" do
    user = User.new(
      nickname: "golden#{random_string}",
      email: "golden#{random_string}@diesel.kg"
    )
    user.salt = nil
    # What "demo1234" would hash to with an empty-string salt -- if the
    # blank-salt guard were missing, authenticating with "demo1234" against
    # this row would incorrectly succeed.
    user.crypted_password = User.encrypt("demo1234", "")
    user.save!(validate: false)

    user.authenticate("demo1234").should be_falsey
  end

  # Regression for the bcrypt-upgrade path calling update_columns, which
  # raises ActiveRecordError on a record with no row to update -- turning a
  # *correct* password into a 500 instead of `true`. No current caller
  # reaches #authenticate on a non-persisted/destroyed record, but a console
  # session or a future caller reasonably could.
  it "authenticates a legacy record that is not persisted, without raising or upgrading its hash" do
    user = User.new(
      nickname: "golden#{random_string}",
      email: "golden#{random_string}@diesel.kg"
    )
    user.salt = golden_vectors.first[:salt]
    user.crypted_password = golden_vectors.first[:crypted_password]

    result = nil
    expect { result = user.authenticate("demo1234") }.not_to raise_error
    expect(result).to be_truthy
    expect(user.password_digest).to be_blank
  end

  it "authenticates a legacy record that has since been destroyed, without raising or upgrading its hash" do
    user = User.new(
      nickname: "golden#{random_string}",
      email: "golden#{random_string}@diesel.kg"
    )
    user.salt = golden_vectors.first[:salt]
    user.crypted_password = golden_vectors.first[:crypted_password]
    user.save!(validate: false)
    user.destroy

    result = nil
    expect { result = user.authenticate("demo1234") }.not_to raise_error
    expect(result).to be_truthy
    expect(user.password_digest).to be_blank
  end
end
