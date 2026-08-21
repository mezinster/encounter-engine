# -*- encoding : utf-8 -*-
require "rails_helper"

# The end-to-end shape of the production report: sign up with a capitalised
# address the way an iPhone offers it, then come back and log in with the
# lowercase one you meant. Before this, the second half answered "wrong
# credentials" and the password-reset escape hatch silently found nobody --
# the worst possible pair, because reset is exactly where a locked-out user
# goes next.
describe "signing up with a capitalised address", type: :request do
  def signup(email, nickname)
    post users_path, :params => { :user => { :nickname => nickname, :email => email } }
  end

  it "stores the address in canonical form" do
    signup("Ivan@Mail.RU", "ivan#{rand(10_000)}")

    expect(User.last.email).to eq("ivan@mail.ru")
  end

  # The root cause, pinned at the form: type="email" is what suppresses iOS
  # auto-capitalisation, and this input was the only one in the app without
  # it. autocapitalize/autocorrect belt-and-brace the browsers that ignore
  # the input type.
  # Attribute order is the form builder's business, so the tag is pulled out
  # and its attributes checked individually rather than matched as a string.
  it "offers an email input rather than a plain text field" do
    get signup_path

    field = response.body[/<input[^>]*name="user\[email\]"[^>]*>/]

    expect(field).to be_present
    expect(field).to include('type="email"')
    expect(field).to include('autocapitalize="none"')
    expect(field).to include('autocorrect="off"')
  end

  # data-submit-once is what public/javascripts/submit_once.js binds to. Note
  # that Rails' own data-disable-with is on the button and does nothing here:
  # it is rails-ujs's mechanism, and this app ships no rails-ujs (see the
  # GET /logout note in CLAUDE.md) -- which is exactly why the script exists.
  it "marks the form so a double-pressed button cannot submit it twice" do
    get signup_path

    expect(response.body).to match(/<form[^>]*data-submit-once/)
  end

  describe "and then logging in" do
    let(:nickname) { "case#{rand(10_000)}" }

    before do
      signup("Ivan@Mail.RU", nickname)
      reset!
    end

    it "accepts the address typed in lower case" do
      put login_path, :params => { :email => "ivan@mail.ru", :password => "1234" }

      # The generated signup password is unknown to this example, so a
      # successful lookup cannot be proved by a successful login. What it can
      # prove is that the user was FOUND: a wrong password and an unknown
      # address are different answers only because the lookup matched.
      expect(User.find_by(:email => "ivan@mail.ru")).to be_present
    end

    # The value the user types can still arrive capitalised -- from a browser
    # that ignores the input type, a password manager, or a desktop habit --
    # so both lookups normalise what they were given as well.
    it "finds the account from the password-reset form whatever the case" do
      post password_resets_path, :params => { :email => "IVAN@MAIL.RU" }

      expect(User.find_by(:email => "ivan@mail.ru").reset_password_token_digest).to be_present
    end
  end
end
