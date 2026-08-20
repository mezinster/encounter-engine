require "rails_helper"

# Reported from production, 2026-08-20: players signing up on an iPhone got
# their address stored capitalised, then could not log in with the lowercase
# one they typed afterwards.
#
# The signup form was the only email input in the app still using
# `text_field` rather than `email_field` (users/new.html.erb) -- and
# `type="email"` is exactly what turns off iOS auto-capitalisation. Both other
# email inputs, login and password reset, were already email fields. So the
# capital was introduced at signup and never afterwards, which is why the
# failure was one-directional and looked so strange: what the user typed at
# login was right, and what the database held was wrong.
#
# The form is the root cause and is fixed too, but a form fix alone protects
# only the browsers that honour it. Normalising on the model makes the stored
# value canonical whatever produced it -- signup, the profile form, a console
# session, a fixture -- and is what lets the unique index below mean
# "one account per address" rather than "one account per spelling".
describe User, "e-mail normalisation" do
  {
    "Ivan@mail.ru"   => "ivan@mail.ru",
    "IVAN@MAIL.RU"   => "ivan@mail.ru",
    "  ivan@mail.ru" => "ivan@mail.ru",
    "ivan@mail.ru  " => "ivan@mail.ru",
    " Ivan@Mail.RU " => "ivan@mail.ru"
  }.each do |typed, stored|
    it "stores #{typed.inspect} as #{stored.inspect}" do
      user = create_user
      user.update!(:email => typed)

      expect(user.reload.email).to eq(stored)
    end
  end

  # strip as well as downcase: a pasted address on a phone keyboard arrives
  # with a trailing space more often than not, and the format validation
  # would otherwise reject an address that is perfectly good.
  it "accepts an address that only a stray space made invalid" do
    user = User.new(:nickname => "spacer#{rand(10_000)}", :email => " spacer@mail.ru ",
                    :password => "1234", :password_confirmation => "1234")

    expect(user).to be_valid
  end

  it "refuses a second account differing from the first only in case" do
    create_user.update!(:email => "taken@mail.ru")

    second = User.new(:nickname => "second#{rand(10_000)}", :email => "Taken@Mail.RU",
                      :password => "1234", :password_confirmation => "1234")

    expect(second).not_to be_valid
    expect(second.errors[:email]).to be_present
  end

  it "leaves an address that is already canonical alone" do
    user = create_user
    user.update!(:email => "plain@mail.ru")

    expect(user.reload.email).to eq("plain@mail.ru")
  end
end
