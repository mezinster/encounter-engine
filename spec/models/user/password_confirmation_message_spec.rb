# -*- encoding : utf-8 -*-
require "rails_helper"

# Fix round 1 regression coverage: ConfirmationValidator attaches its error
# to :password_confirmation, not :password, so the locale key has to live at
# activerecord.errors.models.user.attributes.password_confirmation.confirmation.
# A key placed under .attributes.password.confirmation (where it lived before
# this fix) is never looked up -- I18n.t spot-checks that only prove the key
# HOLDS the right string can't catch that, because they don't go through the
# validator's own lookup path. Asserting on Model#errors here does.
#
# Signup no longer collects a password (product decision 2026-08-08 -- see
# CLAUDE.md, "The acceptance-suite rule", third authorised exception), so this
# message can no longer surface at /signup; the profile-edit path
# (UsersController#update, profile_params) is the only place a mismatched
# confirmation still reaches a real form today.
describe User, "password confirmation validation messages" do
  it "renders the real Russian mismatch message, not a translation-missing placeholder" do
    user = User.new(
      :nickname => "user#{random_string}",
      :email => "user#{random_string}@diesel.kg",
      :password => "1234",
      :password_confirmation => "wrong"
    )

    user.valid?

    user.errors[:password_confirmation].should == ["Пароль и его подтверждение не совпадают"]
  end

  it "requires password_confirmation to be present at all, not just matching when given" do
    # merb-auth's SaltedUser mixin (merb-auth-more/.../ar_salted_user.rb:10,
    # removed by Task 13; see git history) validated presence of
    # :password_confirmation on top of the match check.
    # Rails' ConfirmationValidator returns early when the confirmation is
    # nil, so a signup that omits the field entirely would otherwise pass.
    user = User.new(
      :nickname => "user#{random_string}",
      :email => "user#{random_string}@diesel.kg",
      :password => "1234"
    )

    user.valid?

    user.errors[:password_confirmation].should == ["Вы не ввели подтверждение пароля"]
  end

  it "still accepts a matching confirmation" do
    user = User.new(
      :nickname => "user#{random_string}",
      :email => "user#{random_string}@diesel.kg",
      :password => "1234",
      :password_confirmation => "1234"
    )

    user.valid?

    user.errors[:password_confirmation].should be_empty
  end
end
