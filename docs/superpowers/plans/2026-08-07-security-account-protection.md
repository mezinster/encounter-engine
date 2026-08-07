# Account Protection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an account recoverable by its owner and unrecoverable by anyone else — verify the
current password before changing it, make a password change actually evict stolen sessions, retire
single-round SHA-1 hashing, and stop mailing every new user their password in cleartext.

**Architecture:** Three independently shippable parts. **Part A** (Tasks 1-3) closes the credential-
change holes using only the existing schema plus one new column. **Part B** (Task 4) migrates
password hashing to bcrypt lazily, on successful login, so no user is locked out and the
byte-for-byte legacy formula survives for verification. **Part C** (Tasks 5-6) adds a real password-
reset flow and only then removes the plaintext password from the welcome mail — that ordering is not
optional, because today that mail *is* the recovery mechanism.

**Tech Stack:** Rails 8.0, ActiveRecord migrations, ActionMailer, `bcrypt` (new dependency in Part
B), RSpec.

## Global Constraints

- Ruby 3.3.12 via rbenv, **not on `PATH` in non-login shells**. Prefix every shell command with
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Never edit any file under `features/`** ending in `.feature`. Step definitions are editable.
- Capture a green baseline with `bundle exec rspec` and `bundle exec cucumber` before starting.
- After **every** migration, run `bin/rails db:migrate` and then `bin/rails db:test:prepare`. The
  test database is real sqlite managed through `db/schema.rb` plus
  `ActiveRecord::Migration.maintain_test_schema!`.
- New i18n keys go into **all four** of `config/locales/{ru,en,uk,ka}.yml`. `spec/i18n_spec.rb`
  enforces exact `ru`↔`en` leaf-key parity; `uk`/`ka` may be a subset but this plan supplies all
  four. The `uk` and `ka` strings here were machine-produced without a native reviewer — that
  matches the existing state of those locales; do not describe them as reviewed.
- Hash rockets (`:key => value`) throughout. Match the surrounding file.
- **Never introduce a committed default or fallback for a production secret.** This repository is
  public.

## Part boundaries

| Part | Tasks | Ships independently? | Needs sign-off? |
|---|---|---|---|
| A — credential change | 1, 2, 3 | Yes | No |
| B — bcrypt migration | 4 | Yes (after A, or standalone) | No |
| C — reset flow + mail | 5, 6 | Task 6 depends on Task 5 | **Yes — Task 5 adds a user-facing feature** |

---

## File Structure

**Modified:** `app/controllers/users_controller.rb`, `app/controllers/sessions_controller.rb`,
`app/controllers/concerns/authentication.rb`, `app/models/user.rb`,
`app/views/users/edit.html.erb`, `app/mailers/notification_mailer.rb`,
`app/views/notification_mailer/welcome_letter.text.erb`, `config/routes.rb`, `Gemfile`,
`config/locales/{ru,en,uk,ka}.yml`.

**Created:** three migrations, `app/controllers/password_resets_controller.rb`,
`app/views/password_resets/{new,edit}.html.erb`,
`app/views/notification_mailer/password_reset.text.erb`, and four spec files.

---

## Part A — credential change

### Task 1: Reset the session on signup

**Files:**
- Modify: `app/controllers/users_controller.rb:61-63`
- Test: `spec/requests/signup_session_spec.rb` (create)

**Honest framing:** this is **hardening, not a live vulnerability**, and the plan says so out loud
so nobody oversells it in a changelog. The CSRF-token-fixation attack it theoretically enables does
not survive scrutiny — the attacker capability that defeats `SameSite=Lax` (a sibling subdomain) is
exactly the one `forgery_protection_origin_check` catches, and the only remaining precondition is
XSS, which makes the whole chain redundant. It is worth one line anyway: `SessionsController#create`
resets and `UsersController#create` does not, and that asymmetry will read as a bug to the next
auditor.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/signup_session_spec.rb`:

```ruby
require "rails_helper"

# SessionsController#create calls reset_session before writing :user_id and
# carries a comment explaining why. Registration performs the identical
# anonymous -> authenticated transition and did not.
describe "signing up", type: :request do
  it "issues a fresh session id" do
    get signup_path
    before_id = session.id

    post users_path, :params => { :user => { :nickname => "fresh#{rand(100000)}",
                                             :email => "fresh#{rand(100000)}@example.com",
                                             :password => "1234",
                                             :password_confirmation => "1234" } }

    expect(response).to redirect_to(dashboard_path)
    expect(session.id).not_to eq(before_id)
    expect(session[:user_id]).to be_present
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/signup_session_spec.rb
```

Expected: 1 failure — the session id is unchanged.

- [ ] **Step 3: Implement**

`app/controllers/users_controller.rb:61-63`:

```ruby
  # reset_session before writing :user_id, matching SessionsController#create
  # (sessions_controller.rb:20). Registration is the same anonymous ->
  # authenticated transition, and the session cookie also carries the CSRF
  # token, so the two entry points must look identical.
  def authenticate_user
    reset_session
    session[:user_id] = @user.id
  end
```

- [ ] **Step 4: Run it, then the suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/signup_session_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: green, both suites at baseline plus one example.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/users_controller.rb spec/requests/signup_session_spec.rb
git commit -m "Reset the session on signup, matching login"
```

---

### Task 2: Require the current password before changing it

**Files:**
- Modify: `app/controllers/users_controller.rb:49-57, 83-89`
- Modify: `app/views/users/edit.html.erb:52, 56` (and add the current-password field)
- Modify: `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/requests/password_change_spec.rb` (create)

**Background:** `profile_params` permits `:password`/`:password_confirmation`, and `#update` applies
them to `current_user` with no verification of the existing password. Verified by replaying the
controller's exact call against a real record: the update succeeds, the old password stops working,
the new one works. Combined with the total absence of any recovery flow, momentary access to a
logged-in browser is a **permanent, unrecoverable** account takeover — the victim's only remedy is
direct database access.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/password_change_spec.rb`:

```ruby
require "rails_helper"

describe "changing a password", type: :request do
  let(:user) { create_user }

  before do
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses without the current password" do
    patch user_path(user), :params => { :user => { :password => "hijacked",
                                                   :password_confirmation => "hijacked" } }

    expect(user.reload.authenticate("1234")).to be true
    expect(user.authenticate("hijacked")).to be false
  end

  it "refuses with the wrong current password" do
    patch user_path(user), :params => { :user => { :current_password => "wrong",
                                                   :password => "hijacked",
                                                   :password_confirmation => "hijacked" } }

    expect(user.reload.authenticate("1234")).to be true
  end

  it "accepts with the correct current password" do
    patch user_path(user), :params => { :user => { :current_password => "1234",
                                                   :password => "newpass",
                                                   :password_confirmation => "newpass" } }

    expect(user.reload.authenticate("newpass")).to be true
  end

  # A profile edit that does not touch the password must not demand one.
  it "still lets the rest of the profile be edited without a password" do
    patch user_path(user), :params => { :user => { :phone_number => "+995 555 000000" } }

    expect(user.reload.phone_number).to eq("+995 555 000000")
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/password_change_spec.rb
```

Expected: 4 examples, 2 failures (the first two — the password changes when it should not).

- [ ] **Step 3: Add the i18n key to all four locales**

Under the `users:` block used by the profile form:

```yaml
# ru.yml
      current_password: "Текущий пароль"
      current_password_wrong: "Неверный текущий пароль."
```
```yaml
# en.yml
      current_password: "Current password"
      current_password_wrong: "Current password is incorrect."
```
```yaml
# uk.yml
      current_password: "Поточний пароль"
      current_password_wrong: "Невірний поточний пароль."
```
```yaml
# ka.yml
      current_password: "მიმდინარე პაროლი"
      current_password_wrong: "მიმდინარე პაროლი არასწორია."
```

Place them at the same nesting level as the existing profile-form labels — read the file and match,
do not guess the path.

- [ ] **Step 4: Implement**

`app/controllers/users_controller.rb:49-57`:

```ruby
  def update
    @user = current_user

    # A new password requires proof of the current one. Without this, momentary
    # access to a logged-in browser was a permanent account takeover: the
    # profile form re-hashes on any save where password is present, and this
    # app has no recovery flow, so the victim could not get back in at all.
    if params.dig(:user, :password).present? &&
       !@user.authenticate(params.dig(:user, :current_password).to_s)
      @user.errors.add(:base, t("users.edit.current_password_wrong"))
      render :edit, status: :unprocessable_entity
      return
    end

    if @user.update(profile_params)
      redirect_to users_path
    else
      render :edit, status: :unprocessable_entity
    end
  end
```

`profile_params` stays exactly as it is — `:current_password` is deliberately **not** added to the
permit list, because it is read directly off `params` and must never reach `User#update`.

- [ ] **Step 5: Add the field to the form, and fix the field type while you are here**

In `app/views/users/edit.html.erb`, add above the existing password field:

```erb
  <div class="field">
    <%= f.label :current_password, t("users.edit.current_password") %>
    <%= f.password_field :current_password %>
  </div>
```

And change lines 52 and 56 from `f.text_field` to `f.password_field`. They are `text_field` today,
inconsistent with both signup (`app/views/users/new.html.erb:14,18`) and login
(`app/views/sessions/new.html.erb:14`), so the new password is currently typed in the clear on
screen and is eligible for browser form history.

`f.password_field :current_password` works without a model attribute because `password_field`
renders an empty value by default, but confirm the form builder does not raise — if it does, use
`password_field_tag "user[current_password]"`.

- [ ] **Step 6: Run the test, then the suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/password_change_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: green. Watch `features/games/user-profile-view-and-edit.feature` in particular — it edits
the profile without touching the password, which is exactly what the fourth example pins.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/users_controller.rb app/views/users/edit.html.erb config/locales spec/requests/password_change_spec.rb
git commit -m "Require the current password before changing it

CWE-620. The profile form re-hashed on any save with a password present, with
no verification -- so momentary access to a logged-in browser was a permanent
takeover, permanent because this app has no recovery flow at all. Also switches
the two password inputs from text_field to password_field."
```

---

### Task 3: Make a password change evict other sessions

**Files:**
- Create: `db/migrate/<timestamp>_add_session_token_to_users.rb`
- Modify: `app/models/user.rb`, `app/controllers/concerns/authentication.rb:10-14`,
  `app/controllers/sessions_controller.rb:20-21`, `app/controllers/users_controller.rb`
- Test: `spec/requests/session_eviction_spec.rb` (create)

**Why `reset_session` alone is not enough — this is the part reviewers get wrong.** `reset_session`
in `#update` rotates only the *requesting* browser's session. The store is `CookieStore`, so there
is no server-side session record to delete, and `session_options` carries no `expire_after`: an
attacker's separately-held cookie stays valid indefinitely because `current_user` reads nothing but
`session[:user_id]`. Evicting other devices requires binding the session to a value that changes
when the credential changes.

**Deploy consequence, state it in the release notes:** every currently-logged-in user is signed out
once when this ships, because their existing cookie carries no `:session_token`. That is correct and
one-time.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/session_eviction_spec.rb`:

```ruby
require "rails_helper"

# CookieStore has no server-side session record, so a stolen cookie stays valid
# forever unless the session is bound to something that changes with the
# credential.
describe "session eviction on password change", type: :request do
  let(:user) { create_user }

  it "stops accepting a session issued before the password changed" do
    put login_path, :params => { :email => user.email, :password => "1234" }
    stolen = session[:session_token]
    expect(stolen).to be_present

    user.update!(:password => "rotated", :password_confirmation => "rotated")

    expect(user.reload.session_token).not_to eq(stolen)
  end

  it "keeps the changing browser signed in" do
    put login_path, :params => { :email => user.email, :password => "1234" }

    patch user_path(user), :params => { :user => { :current_password => "1234",
                                                   :password => "rotated",
                                                   :password_confirmation => "rotated" } }

    get dashboard_path
    expect(response).to have_http_status(:ok)
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/session_eviction_spec.rb
```

Expected: failures — `session_token` does not exist.

- [ ] **Step 3: Write the migration**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails generate migration AddSessionTokenToUsers
```

Fill it in:

```ruby
class AddSessionTokenToUsers < ActiveRecord::Migration[8.0]
  def up
    add_column :users, :session_token, :string

    # Backfill so every existing row has one. Rows left null would authenticate
    # against a null token, which is exactly the check this column exists to
    # perform.
    User.reset_column_information
    User.find_each { |user| user.update_column(:session_token, SecureRandom.hex(20)) }
  end

  def down
    remove_column :users, :session_token
  end
end
```

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails db:migrate
bin/rails db:test:prepare
```

- [ ] **Step 4: Implement the rotation and the check**

In `app/models/user.rb`, alongside the existing `before_save :encrypt_password`:

```ruby
  # Rotated whenever the password changes, and compared in
  # Authentication#current_user. CookieStore keeps no server-side session
  # record, so this column is the only thing that can invalidate a cookie held
  # by someone else -- reset_session rotates the requesting browser only.
  before_save :rotate_session_token, if: -> { password.present? }
  before_create :ensure_session_token
```

and in the private section:

```ruby
  def rotate_session_token
    self.session_token = SecureRandom.hex(20)
  end

  def ensure_session_token
    self.session_token ||= SecureRandom.hex(20)
  end
```

`app/controllers/concerns/authentication.rb:10-14`:

```ruby
  def current_user
    return @current_user if defined?(@current_user)

    user = session[:user_id] && User.find_by(id: session[:user_id])
    # The token binds this cookie to the credential it was issued under. A
    # cookie minted before a password change no longer resolves, which is what
    # evicts a stolen session -- reset_session cannot, because it only rotates
    # the browser making the request.
    @current_user = if user && user.session_token.present? &&
                       ActiveSupport::SecurityUtils.secure_compare(
                         session[:session_token].to_s, user.session_token)
                      user
                    end
  end
```

`app/controllers/sessions_controller.rb`, after `reset_session` on line 20:

```ruby
      reset_session
      session[:user_id] = user.id
      session[:session_token] = user.session_token
```

And in `UsersController#authenticate_user` (Task 1 already added `reset_session` there):

```ruby
  def authenticate_user
    reset_session
    session[:user_id] = @user.id
    session[:session_token] = @user.session_token
  end
```

Finally, in `UsersController#update`, re-issue the requesting browser's session after a successful
password change so the user is not signed out by their own action. Inside the success branch:

```ruby
    if @user.update(profile_params)
      if params.dig(:user, :password).present?
        reset_session
        session[:user_id] = @user.id
        session[:session_token] = @user.reload.session_token
      end
      redirect_to users_path
```

- [ ] **Step 5: Run the test, then the suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/session_eviction_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: green. If Cucumber fails broadly with unauthenticated redirects, a login path is writing
`:user_id` without `:session_token` — grep for `session[:user_id] =` and confirm all call sites were
updated.

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/user.rb app/controllers spec/requests/session_eviction_spec.rb
git commit -m "Bind sessions to a rotating token so a password change evicts them

CookieStore keeps no server-side session record, so reset_session rotates only
the requesting browser and a stolen cookie stayed valid indefinitely. Every
current session is invalidated once on deploy; that is expected."
```

---

## Part B — hashing

### Task 4: Migrate password hashing to bcrypt, lazily

**Files:**
- Modify: `Gemfile`, `app/models/user.rb`
- Create: `db/migrate/<timestamp>_add_password_digest_to_users.rb`
- Test: `spec/models/user/bcrypt_migration_spec.rb` (create)

**Background:** `Digest::SHA1.hexdigest("--#{salt}--#{password}--")` is one pass with no work
factor. Salts are strong for new rows, so rainbow tables and cross-user amortisation are out — but
per-user offline brute force runs at roughly 10^10 guesses/second on commodity GPUs, and
`validates :password, length: { minimum: 4 }` means the entire 4-character keyspace falls in under
a second. The rows also hold `phone_number`, `date_of_birth`, `telegram_id` and `instagram` for
players who physically show up at locations.

**The constraint that governs the design:** `app/models/user.rb:93-103` documents that the legacy
formula was verified byte-for-byte against real database pairs, and that changing it silently locks
out every existing user — a mismatched hash raises nothing, the login form just rejects a correct
password. So the legacy path must survive for verification, and upgrade must happen only on a
*successful* authentication where the plaintext is in hand.

- [ ] **Step 1: Add the dependency**

In `Gemfile`, next to the other top-level gems:

```ruby
gem "bcrypt", "~> 3.1"
```

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle install
```

- [ ] **Step 2: Write the failing test**

Create `spec/models/user/bcrypt_migration_spec.rb`:

```ruby
require "rails_helper"

describe User, "password hashing" do
  it "stores new passwords as bcrypt" do
    user = create_user

    expect(user.password_digest).to be_present
    expect(BCrypt::Password.new(user.password_digest)).to eq("1234")
  end

  it "still verifies a legacy SHA-1 row" do
    user = create_user
    legacy_salt = "abc123"
    user.update_columns(:password_digest => nil,
                        :salt => legacy_salt,
                        :crypted_password => User.encrypt("legacypass", legacy_salt))

    expect(user.reload.authenticate("legacypass")).to be true
    expect(user.authenticate("wrong")).to be false
  end

  it "upgrades a legacy row on successful authentication" do
    user = create_user
    legacy_salt = "abc123"
    user.update_columns(:password_digest => nil,
                        :salt => legacy_salt,
                        :crypted_password => User.encrypt("legacypass", legacy_salt))

    user.reload.authenticate("legacypass")

    expect(user.reload.password_digest).to be_present
    expect(BCrypt::Password.new(user.password_digest)).to eq("legacypass")
  end

  it "does not upgrade on a failed authentication" do
    user = create_user
    legacy_salt = "abc123"
    user.update_columns(:password_digest => nil,
                        :salt => legacy_salt,
                        :crypted_password => User.encrypt("legacypass", legacy_salt))

    user.reload.authenticate("wrong")

    expect(user.reload.password_digest).to be_nil
  end
end
```

- [ ] **Step 3: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/user/bcrypt_migration_spec.rb
```

Expected: 4 failures — `password_digest` does not exist.

- [ ] **Step 4: Migration**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails generate migration AddPasswordDigestToUsers password_digest:string
bin/rails db:migrate
bin/rails db:test:prepare
```

The `crypted_password` and `salt` columns stay — they are the verification path for every user who
has not logged in since the deploy. Do not drop them in this task; that is a separate cleanup once
the digest is backfilled for everyone who is still active.

- [ ] **Step 5: Implement**

In `app/models/user.rb`, replace `encrypt_password` and `authenticate`:

```ruby
  # New passwords are bcrypt. self.encrypt below is retained unchanged for
  # verifying rows written by the Merb app -- see the comment on it; the
  # formula was verified byte-for-byte against real (salt, crypted_password)
  # pairs and changing it silently locks those users out, because a mismatched
  # hash raises nothing and the login form just rejects a correct password.
  def encrypt_password
    self.password_digest = BCrypt::Password.create(password)
  end

  # Verification order: bcrypt if this row has been upgraded, legacy SHA-1
  # otherwise. A successful legacy verification upgrades the row in place --
  # that is the only moment the plaintext is available, so it is the only
  # moment an upgrade is possible. A failed attempt upgrades nothing.
  def authenticate(candidate)
    if password_digest.present?
      return BCrypt::Password.new(password_digest).is_password?(candidate)
    end

    return false if crypted_password.blank? || salt.blank?
    return false unless self.class.encrypt(candidate, salt) == crypted_password

    update_column(:password_digest, BCrypt::Password.create(candidate))
    true
  end
```

Keep `self.encrypt`, its comment, `password_required?`, and the `before_save :encrypt_password,
if: -> { password.present? }` line exactly as they are.

Note `self.salt ||= SecureRandom.hex(20)` is no longer reached for new passwords, which also
resolves the related defect that a user changing their password kept a legacy salt derived from a
one-second-resolution timestamp.

- [ ] **Step 6: Run the test, then everything**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/user/bcrypt_migration_spec.rb
bundle exec rspec spec/models/user
bundle exec rspec
bundle exec cucumber
```

Expected: green. `spec/models/user/authenticate_spec.rb` contains the two real
`(salt, crypted_password)` vectors captured from the running Merb app — those must still pass, and
they are the proof the legacy path survives.

- [ ] **Step 7: Commit**

```bash
git add Gemfile Gemfile.lock db/migrate db/schema.rb app/models/user.rb spec/models/user/bcrypt_migration_spec.rb
git commit -m "Hash new passwords with bcrypt, upgrading legacy rows on login

Single-round salted SHA-1 has no work factor; with a 4-character minimum the
whole keyspace falls in under a second on a GPU. The Merb-era formula is kept
for verification -- it was verified byte-for-byte against real database pairs
and changing it would silently lock those users out -- and each row upgrades on
its owner's next successful login, the only moment the plaintext exists."
```

---

## Part C — recovery, then removing the mailed password

> **Requires sign-off before starting.** Task 5 adds a user-facing feature (a password-reset flow
> with its own screens and mail). Task 6 removes the plaintext password from the welcome mail and
> **must not** ship before Task 5, because that mail is currently the only way a user who forgets
> their password gets back in — there is no reset flow, and a superadmin cannot reset one either.

### Task 5: Add a password-reset flow

**Files:**
- Create: `db/migrate/<timestamp>_add_reset_password_to_users.rb`
- Create: `app/controllers/password_resets_controller.rb`,
  `app/views/password_resets/new.html.erb`, `app/views/password_resets/edit.html.erb`,
  `app/views/notification_mailer/password_reset.text.erb`
- Modify: `config/routes.rb`, `app/models/user.rb`, `app/mailers/notification_mailer.rb`,
  `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/requests/password_reset_spec.rb` (create)

**Design decisions, so the implementer does not have to make them:**
- The token is `SecureRandom.urlsafe_base64(32)`; only its SHA-256 digest is stored. A database
  disclosure therefore does not yield usable reset tokens.
- Comparison uses `ActiveSupport::SecurityUtils.secure_compare` on the digests.
- Expiry is two hours, checked server-side.
- The token is single-use: cleared on successful reset.
- `#create` responds identically whether or not the email exists — no account enumeration, matching
  the login form's existing behaviour.
- A successful reset rotates `session_token` (Part A Task 3), so completing a reset evicts every
  other session. That is the point of doing Part A first.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/password_reset_spec.rb`:

```ruby
require "rails_helper"

describe "password reset", type: :request do
  let(:user) { create_user }

  def request_reset_for(email)
    post password_resets_path, :params => { :email => email }
  end

  def token_from_last_mail
    ActionMailer::Base.deliveries.last.body.to_s[%r{/password/edit\?token=([A-Za-z0-9_-]+)}, 1]
  end

  before { ActionMailer::Base.deliveries.clear }

  it "mails a working token" do
    request_reset_for(user.email)

    token = token_from_last_mail
    expect(token).to be_present

    patch password_reset_path, :params => { :token => token,
                                            :user => { :password => "brandnew",
                                                       :password_confirmation => "brandnew" } }

    expect(user.reload.authenticate("brandnew")).to be true
  end

  it "does not reveal whether an address is registered" do
    request_reset_for(user.email)
    known = response.body

    request_reset_for("nobody#{rand(100000)}@example.com")

    expect(response.body).to eq(known)
    expect(ActionMailer::Base.deliveries.length).to eq(1)
  end

  it "refuses an expired token" do
    request_reset_for(user.email)
    token = token_from_last_mail
    user.update_column(:reset_password_sent_at, 3.hours.ago)

    patch password_reset_path, :params => { :token => token,
                                            :user => { :password => "brandnew",
                                                       :password_confirmation => "brandnew" } }

    expect(user.reload.authenticate("brandnew")).to be false
  end

  it "refuses a token twice" do
    request_reset_for(user.email)
    token = token_from_last_mail

    patch password_reset_path, :params => { :token => token,
                                            :user => { :password => "first",
                                                       :password_confirmation => "first" } }
    patch password_reset_path, :params => { :token => token,
                                            :user => { :password => "second",
                                                       :password_confirmation => "second" } }

    expect(user.reload.authenticate("first")).to be true
    expect(user.authenticate("second")).to be false
  end
end
```

- [ ] **Step 2: Run it and watch it fail** (`password_resets_path` is undefined)

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/password_reset_spec.rb
```

- [ ] **Step 3: Migration**

```ruby
class AddResetPasswordToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :reset_password_token_digest, :string
    add_column :users, :reset_password_sent_at, :datetime
    add_index  :users, :reset_password_token_digest
  end
end
```

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails db:migrate && bin/rails db:test:prepare
```

- [ ] **Step 4: Model support**

In `app/models/user.rb`:

```ruby
  RESET_PASSWORD_VALID_FOR = 2.hours

  # Only the digest is stored: a database disclosure must not yield usable
  # reset tokens. The raw token is returned once, for the mail, and never
  # persisted.
  def issue_reset_password_token!
    raw = SecureRandom.urlsafe_base64(32)
    update_columns(:reset_password_token_digest => self.class.digest_reset_token(raw),
                   :reset_password_sent_at => Time.now.utc)
    raw
  end

  def self.digest_reset_token(raw)
    Digest::SHA256.hexdigest(raw.to_s)
  end

  def self.find_by_reset_token(raw)
    return nil if raw.blank?

    digest = digest_reset_token(raw)
    candidate = where.not(:reset_password_token_digest => nil).find_by(:reset_password_token_digest => digest)
    return nil unless candidate
    return nil if candidate.reset_password_sent_at.blank?
    return nil if candidate.reset_password_sent_at < RESET_PASSWORD_VALID_FOR.ago

    candidate
  end

  def clear_reset_password_token!
    update_columns(:reset_password_token_digest => nil, :reset_password_sent_at => nil)
  end
```

Add `require "digest/sha2"` at the top alongside the existing `require "digest/sha1"`.

- [ ] **Step 5: Routes**

In `config/routes.rb`, next to the other session/registration routes around line 47:

```ruby
  get   "/password/new",  to: "password_resets#new",    as: :new_password_reset
  post  "/password",      to: "password_resets#create", as: :password_resets
  get   "/password/edit", to: "password_resets#edit",   as: :edit_password_reset
  patch "/password",      to: "password_resets#update", as: :password_reset
```

- [ ] **Step 6: Controller**

Create `app/controllers/password_resets_controller.rb`:

```ruby
# -*- encoding : utf-8 -*-
class PasswordResetsController < ApplicationController
  def new
  end

  # Responds identically whether or not the address is registered. The login
  # form already refuses to distinguish "no such e-mail" from "wrong password"
  # (sessions_controller.rb:24) and this must not undo that.
  def create
    user = User.find_by(email: params[:email].to_s.strip)

    if user
      token = user.issue_reset_password_token!
      NotificationMailer.password_reset(user, token).deliver_now
    end

    redirect_to login_path, notice: t("password_resets.create.sent")
  end

  def edit
    @token = params[:token].to_s
    redirect_to new_password_reset_path, alert: t("password_resets.invalid") unless User.find_by_reset_token(@token)
  end

  def update
    @token = params[:token].to_s
    user = User.find_by_reset_token(@token)

    unless user
      redirect_to new_password_reset_path, alert: t("password_resets.invalid")
      return
    end

    if user.update(password: params.dig(:user, :password),
                   password_confirmation: params.dig(:user, :password_confirmation))
      # Single use, and the password change has already rotated session_token
      # (see AddSessionTokenToUsers), so every other session is now dead.
      user.clear_reset_password_token!
      reset_session
      redirect_to login_path, notice: t("password_resets.update.done")
    else
      @user = user
      render :edit, status: :unprocessable_entity
    end
  end
end
```

- [ ] **Step 7: Mailer, views and locale keys**

`app/mailers/notification_mailer.rb`, alongside `welcome_letter`:

```ruby
  def password_reset(user, token)
    @user = user
    @host = app_host
    @token = token
    mail_in_recipient_locale(user, :password_reset)
  end
```

`app/views/notification_mailer/password_reset.text.erb`:

```erb
<%= t("notification_mailer.password_reset.body",
      nickname: @user.nickname,
      url: edit_password_reset_url(token: @token),
      hours: (User::RESET_PASSWORD_VALID_FOR / 1.hour).to_i) %>
```

`app/views/password_resets/new.html.erb`:

```erb
<h1><%= t("password_resets.new.title") %></h1>

<%= form_with url: password_resets_path, method: :post do |f| %>
  <div class="field">
    <%= label_tag :email, t("password_resets.new.email") %>
    <%= email_field_tag :email %>
  </div>
  <%= submit_tag t("password_resets.new.submit"), class: "btn btn--go" %>
<% end %>
```

`app/views/password_resets/edit.html.erb`:

```erb
<h1><%= t("password_resets.edit.title") %></h1>

<%= error_messages_for @user if @user %>

<%= form_with url: password_reset_path, method: :patch do |f| %>
  <%= hidden_field_tag :token, @token %>
  <div class="field">
    <%= label_tag "user[password]", t("password_resets.edit.password") %>
    <%= password_field_tag "user[password]" %>
  </div>
  <div class="field">
    <%= label_tag "user[password_confirmation]", t("password_resets.edit.password_confirmation") %>
    <%= password_field_tag "user[password_confirmation]" %>
  </div>
  <%= submit_tag t("password_resets.edit.submit"), class: "btn btn--go" %>
<% end %>
```

Add a link to `new_password_reset_path` from `app/views/sessions/new.html.erb`, labelled
`t("password_resets.new.link")`.

Locale keys, in all four files. Russian and English are given in full below; `uk` and `ka` mirror
the same structure and must carry the same interpolation variables (`%{nickname}`, `%{url}`,
`%{hours}` in `body`; `%{host}` in `subject` — both supplied by `subject_vars`).

`config/locales/ru.yml`
```yaml
  password_resets:
    invalid: "Ссылка для сброса пароля недействительна или устарела."
    new:
      title: "Восстановление пароля"
      email: "Email"
      submit: "Отправить ссылку"
      link: "Забыли пароль?"
    edit:
      title: "Новый пароль"
      password: "Новый пароль"
      password_confirmation: "Подтверждение пароля"
      submit: "Сохранить пароль"
    create:
      sent: "Если такой адрес зарегистрирован, мы отправили на него ссылку для сброса пароля."
    update:
      done: "Пароль изменён. Войдите с новым паролем."
```
and, under the existing `notification_mailer:` block:
```yaml
    password_reset:
      subject: "Сброс пароля на %{host}"
      body: |
        %{nickname}, кто-то запросил сброс пароля для вашей учётной записи.

        Чтобы задать новый пароль, перейдите по ссылке:
        %{url}

        Ссылка действует %{hours} ч. Если вы не запрашивали сброс, просто
        проигнорируйте это письмо — пароль останется прежним.
```

`config/locales/en.yml`
```yaml
  password_resets:
    invalid: "This password reset link is invalid or has expired."
    new:
      title: "Reset your password"
      email: "Email"
      submit: "Send the link"
      link: "Forgot your password?"
    edit:
      title: "New password"
      password: "New password"
      password_confirmation: "Confirm password"
      submit: "Save password"
    create:
      sent: "If that address is registered, we have sent it a password reset link."
    update:
      done: "Password changed. Sign in with your new password."
```
```yaml
    password_reset:
      subject: "Password reset at %{host}"
      body: |
        %{nickname}, someone asked to reset the password for your account.

        To set a new password, follow this link:
        %{url}

        The link is valid for %{hours} hours. If you did not ask for a reset,
        ignore this message — your password is unchanged.
```

Note the deliberately non-committal wording of `create.sent`: it must not confirm whether the
address is registered, which is what the second example in Step 1 pins.

- [ ] **Step 8: Run the test, then everything**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/password_reset_spec.rb
bundle exec rspec spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: green. `spec/i18n_spec.rb` will fail loudly if any `ru` key lacks its `en` twin.

- [ ] **Step 9: Commit**

```bash
git add db/migrate db/schema.rb config/routes.rb app/controllers/password_resets_controller.rb \
        app/views/password_resets app/views/notification_mailer/password_reset.text.erb \
        app/mailers/notification_mailer.rb app/models/user.rb app/views/sessions/new.html.erb \
        config/locales spec/requests/password_reset_spec.rb
git commit -m "Add a password reset flow

Only the SHA-256 digest of the token is stored, so a database disclosure does
not yield usable tokens. Two-hour expiry, single use, and no account
enumeration -- the response is identical for an unregistered address, matching
the login form. A completed reset rotates session_token, so it also evicts
every other session."
```

---

### Task 6: Stop mailing the plaintext password

**Files:**
- Modify: `app/controllers/users_controller.rb:96-98`, `app/mailers/notification_mailer.rb:15-20`,
  `app/views/notification_mailer/welcome_letter.text.erb:15-18`,
  `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/mailers/welcome_letter_spec.rb` (create or extend)

**Do not start this task until Task 5 has shipped.**

- [ ] **Step 1: Write the failing test**

Create `spec/mailers/welcome_letter_spec.rb`:

```ruby
require "rails_helper"

describe NotificationMailer, "welcome_letter" do
  it "does not contain the plaintext password" do
    user = User.new(:nickname => "newbie", :email => "newbie@example.com",
                    :password => "SuperSecret123", :password_confirmation => "SuperSecret123")
    user.save!

    mail = NotificationMailer.welcome_letter(user)

    expect(mail.body.to_s).not_to include("SuperSecret123")
    expect(mail.body.to_s).to include(user.email)
  end
end
```

- [ ] **Step 2: Run it and watch it fail** (on arity — the mailer still takes two arguments)

- [ ] **Step 3: Implement**

`app/controllers/users_controller.rb:96-98`:

```ruby
  def send_welcome_letter_to(user)
    NotificationMailer.welcome_letter(user).deliver_now
  end
```

`app/mailers/notification_mailer.rb:15-20`:

```ruby
  def welcome_letter(user)
    @user = user
    @host = app_host
    mail_in_recipient_locale(user, :welcome_letter)
  end
```

Remove the `password: @password` interpolation from
`app/views/notification_mailer/welcome_letter.text.erb`, and remove the
`Пароль: %{password}` / `Password: %{password}` line from the
`notification_mailer.welcome_letter.body` value in **all four** locale files. Point the letter at
the reset flow instead — add a line referencing `new_password_reset_url`.

- [ ] **Step 4: Run the test, i18n parity, and everything**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/mailers spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: green. Check `features/signup` in particular.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/users_controller.rb app/mailers/notification_mailer.rb \
        app/views/notification_mailer/welcome_letter.text.erb config/locales spec/mailers
git commit -m "Stop mailing new users their plaintext password

The password sat in cleartext in the recipient's mailbox indefinitely, in the
SMTP relay's logs, and on the wire whenever opportunistic STARTTLS did not
negotiate. The effort spent keeping passwords out of request logs
(config/application.rb:42) was undone by mailing them. The reset flow added in
the previous task replaces the recovery role this mail was implicitly playing."
```

---

## Definition of done

- Both suites green at baseline plus the new examples, after each part.
- `db/schema.rb` is committed with each migration.
- The Task 3 deploy consequence — every user signed out once — is in the release notes.
- No plaintext password appears in any mail body, log line, or committed file.
