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
  GOLDEN_VECTORS = [
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

  GOLDEN_VECTORS.each do |vector|
    it "verifies the real merb-auth hash captured for #{vector[:email]}" do
      User.encrypt("demo1234", vector[:salt]).should == vector[:crypted_password]
    end
  end

  it "authenticates a User whose crypted_password/salt come straight from the Merb database, without re-hashing them" do
    user = User.new(
      nickname: "golden#{random_string}",
      email: "golden#{random_string}@diesel.kg"
    )
    user.salt = GOLDEN_VECTORS.first[:salt]
    user.crypted_password = GOLDEN_VECTORS.first[:crypted_password]
    user.save!(validate: false)

    user.authenticate("demo1234").should be_truthy
    user.authenticate("wrong-password").should be_falsey
  end
end
