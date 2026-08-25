# SMTP Outage Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An SMTP failure must never destroy state, never strand an account, and never go unnoticed.

**Architecture:** A single `MailDelivery.attempt { ... }` seam rescues *transport* errors only and
returns a boolean; six call sites branch on it. Signup shows the generated password on screen when
the letter could not be sent. A 6-hourly GitHub Actions probe authenticates against both the live
credential and a warm Fastmail spare without sending anything.

**Tech Stack:** Rails 8, Ruby 3.3.12, RSpec (legacy `should` syntax enabled), Cucumber (Russian
Gherkin), Kamal 2, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-25-smtp-outage-resilience-design.md`

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Prefix every command with
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Isolate the test database.** Another session may hold `db/test.sqlite3`. Export
  `DATABASE_URL="sqlite3:$SCRATCH/test.sqlite3"` and run `bin/rails db:test:prepare` once before the
  first spec run, where `$SCRATCH` is the session scratchpad directory.
- **Never edit a `.feature` file.** Not one byte. This plan requires no amendment, and §2 of the
  spec explains why. If a feature file appears to need changing, stop and report.
- **New i18n keys go in all seven locale files**: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`.
  `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and subset-of-`ru` for the other five.
- **Turkish and Georgian must not inflect around a user-authored placeholder.** A key carrying
  `%{nickname}` puts the case suffix on a common noun (`«%{nickname}» adlı oyuncu`), never on the
  name itself.
- **Hash rockets and `# -*- encoding : utf-8 -*-`**: match the surrounding file. Do not convert
  existing style.
- **Rescue transport errors only.** Never `StandardError`. A template bug or a missing translation
  must keep raising.
- **Never log or commit a credential.** Not the generated password, not an SMTP password.

---

## File Structure

| Path | Responsibility |
|---|---|
| `app/services/mail_delivery.rb` | **New.** The one place that knows which errors are survivable. |
| `app/views/users/welcome_password.html.erb` | **New.** Signup failure page; shows the password once. |
| `ops/smtp/probe.rb` | **New.** SMTP handshake + a pure `classify` verdict function. |
| `.github/workflows/smtp-probe.yml` | **New.** 6-hourly schedule; files an issue on failure. |
| `docs/runbooks/smtp-failover.md` | **New.** Cutover procedure. |
| `spec/services/mail_delivery_spec.rb` | **New.** Pins the rescue list in both directions. |
| `spec/requests/mail_failure_spec.rb` | **New.** The five request-level examples. |
| `spec/ops/smtp_probe_spec.rb` | **New.** `classify` from inline fixtures, no network. |
| `app/controllers/users_controller.rb` | Modify `#create` (lines 74-80). |
| `app/controllers/password_resets_controller.rb` | Modify `#create` (lines 28-30). |
| `app/controllers/invitations_controller.rb` | Modify four sites (21, 37, 47, 76). |
| `config/locales/*.yml` | 8 new keys × 7 files. |
| `CLAUDE.md` | Mail-failure policy; recounted i18n leaf total. |

---

## Task 1: The `MailDelivery` seam

**Files:**
- Create: `app/services/mail_delivery.rb`
- Test: `spec/services/mail_delivery_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `MailDelivery.attempt { ... } # => true | false`. Returns `true` when the block
  completes, `false` when it raises a transport error. Also `MailDelivery::TRANSPORT_ERRORS`
  (frozen Array) and `MailDelivery::MESSAGE_LIMIT` (Integer, 200).

- [ ] **Step 1: Write the failing test**

Create `spec/services/mail_delivery_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# The value of this class is entirely in WHICH errors it swallows, so both
# directions are pinned: transport failures return false, and everything else
# still raises. A rescue later widened to StandardError passes every example
# that only checks the first half -- which is why the second half exists.
describe MailDelivery do
  describe "transport failures" do
    # Constructed from plain strings; none of these needs a real SMTP
    # conversation. Verified 2026-08-25 against ruby 3.3.12.
    {
      "Net::SMTPAuthenticationError" => Net::SMTPAuthenticationError.new("535 5.7.8 Username and Password not accepted"),
      "Net::SMTPFatalError"          => Net::SMTPFatalError.new("550 5.4.5 Daily user sending limit exceeded"),
      "Net::SMTPServerBusy"          => Net::SMTPServerBusy.new("421 Try again later"),
      "Net::SMTPSyntaxError"         => Net::SMTPSyntaxError.new("501 Syntax error"),
      "Net::SMTPUnknownError"        => Net::SMTPUnknownError.new("Unknown response"),
      "Net::OpenTimeout"             => Net::OpenTimeout.new("execution expired"),
      "Net::ReadTimeout"             => Net::ReadTimeout.new,
      "SocketError"                  => SocketError.new("getaddrinfo: Name or service not known"),
      "OpenSSL::SSL::SSLError"       => OpenSSL::SSL::SSLError.new("SSL_connect returned=1"),
      "Errno::ECONNREFUSED"          => Errno::ECONNREFUSED.new,
      "Errno::ECONNRESET"            => Errno::ECONNRESET.new,
      "Errno::EHOSTUNREACH"          => Errno::EHOSTUNREACH.new,
      "Errno::ETIMEDOUT"             => Errno::ETIMEDOUT.new,
      "Errno::ENETUNREACH"           => Errno::ENETUNREACH.new
    }.each do |name, error|
      it "returns false for #{name}" do
        expect(described_class.attempt { raise error }).to eq(false)
      end
    end
  end

  describe "everything else" do
    # These MUST still blow up. A missing translation key or a typo in a mailer
    # template is a bug to fix, not weather to survive; swallowing it trades a
    # visible outage for an invisible one.
    it "lets a NoMethodError through" do
      expect { described_class.attempt { raise NoMethodError, "undefined method" } }
        .to raise_error(NoMethodError)
    end

    it "lets a missing translation through" do
      expect { described_class.attempt { raise I18n::MissingTranslationData.new(:ru, "x", {}) } }
        .to raise_error(I18n::MissingTranslationData)
    end
  end

  it "returns true when the block completes" do
    expect(described_class.attempt { :delivered }).to eq(true)
  end

  it "logs the error class and a truncated message" do
    allow(Rails.logger).to receive(:error)

    described_class.attempt { raise Net::SMTPFatalError.new("550 " + ("x" * 500)) }

    expect(Rails.logger).to have_received(:error) do |line|
      expect(line).to include("Net::SMTPFatalError")
      expect(line.length).to be < 300
    end
  end
end
```

- [ ] **Step 2: Run the test and watch it fail for the right reason**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/services/mail_delivery_spec.rb
```

Expected: every example errors with `NameError: uninitialized constant MailDelivery`.

If instead you see `NameError: uninitialized constant Net::SMTPError`, that is the **next** step's
problem arriving early — read Step 3's note before continuing.

- [ ] **Step 3: Write the implementation**

Create `app/services/mail_delivery.rb`:

```ruby
# -*- encoding : utf-8 -*-
#
# The rescue seam between a controller and SMTP.
#
# Every mail in this app is delivered synchronously inside the request
# (config.active_job.queue_adapter = :inline, and raise_delivery_errors is
# Rails' default true), so before this class existed an SMTP failure was an
# exception in a controller. In UsersController#create that committed a user
# row, lost the session cookie (ShowExceptions sits ABOVE Session::CookieStore
# in the middleware stack, so the session is never written), and destroyed the
# only copy of a generated password. See
# docs/superpowers/specs/2026-08-25-smtp-outage-resilience-design.md §0.1.
#
# NOT namespaced as Mail::Delivery: the `mail` gem owns the top-level ::Mail
# constant, and app/services/mail/delivery.rb would have Zeitwerk reopen the
# gem's module.
require "net/smtp"
require "openssl"

class MailDelivery
  # Net::SMTPError is a MODULE, not a class. It is mixed into five error
  # classes with five DIFFERENT superclasses (Net::ProtoAuthError,
  # Net::ProtoServerError, Net::ProtoSyntaxError, Net::ProtoFatalError,
  # Net::ProtoUnknownError) -- there is no common ancestor class to rescue.
  # `rescue` dispatches with Module#===, which is why naming the module works.
  #
  # Net::OpenTimeout descends from Timeout::Error, NOT IOError, so it needs its
  # own entry -- and it is the single most likely failure here, since a
  # blackholed connection is more common than a refused one.
  #
  # The `require "net/smtp"` above is load-bearing. The mail gem requires
  # net/smtp lazily, only when SMTP delivery actually runs, and development and
  # test both use delivery_method = :test -- so Net::SMTPError is undefined in
  # a booted app. Without the require this array raises NameError at class-load
  # time in test and development while working perfectly in production.
  TRANSPORT_ERRORS = [
    Net::SMTPError,
    Net::OpenTimeout,
    Net::ReadTimeout,
    SocketError,
    OpenSSL::SSL::SSLError,
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::EHOSTUNREACH,
    Errno::ETIMEDOUT,
    Errno::ENETUNREACH
  ].freeze

  # An SMTP rejection quotes the offending recipient back at you, so the
  # message is truncated rather than logged whole -- log aggregation is not
  # where anyone's address should end up.
  MESSAGE_LIMIT = 200

  # Yields, and reports whether the mail got out.
  #
  #   MailDelivery.attempt { NotificationMailer.welcome_letter(u, p).deliver_now }
  #   # => true | false
  #
  # Deliberately NOT rescuing StandardError. See the spec.
  def self.attempt
    yield
    true
  rescue *TRANSPORT_ERRORS => e
    Rails.logger.error(
      "[mail] delivery failed: #{e.class}: #{e.message.to_s[0, MESSAGE_LIMIT]}"
    )
    false
  end
end
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
bundle exec rspec spec/services/mail_delivery_spec.rb
```

Expected: all examples pass (17 of them).

- [ ] **Step 5: Verify autoloading is not confused by the new constant**

```bash
bin/rails zeitwerk:check
```

Expected: `All is good!`. This is not ceremony — it is the check that
`MailDelivery` did not collide with the `mail` gem's `::Mail`.

- [ ] **Step 6: Commit**

```bash
git add app/services/mail_delivery.rb spec/services/mail_delivery_spec.rb
git commit -m "Add MailDelivery, the transport-error rescue seam"
```

---

## Task 2: The signup failure page

**Files:**
- Modify: `app/controllers/users_controller.rb:74-80`
- Create: `app/views/users/welcome_password.html.erb`
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/requests/mail_failure_spec.rb`

**Interfaces:**
- Consumes: `MailDelivery.attempt` from Task 1.
- Produces: the view reads `@generated_password` (String). Five i18n keys under
  `users.create.mail_failed.*`.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/mail_failure_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# What these examples protect is stated in
# docs/superpowers/specs/2026-08-25-smtp-outage-resilience-design.md §0.1: with
# SMTP down, signup used to commit a user row, fail to write the session
# cookie, and lose the only copy of a server-generated password -- an account
# nobody could ever log into, whose e-mail address was now taken.
describe "when SMTP is down", type: :request do
  # Raised from the delivery itself, so MailDelivery's own rescue is exercised
  # rather than stubbed away.
  def break_smtp!
    allow_any_instance_of(ActionMailer::MessageDelivery)
      .to receive(:deliver_now)
      .and_raise(Net::SMTPAuthenticationError.new("535 5.7.8 Username and Password not accepted"))
  end

  describe "signup" do
    it "keeps the account and shows the generated password" do
      break_smtp!

      post users_path, :params => { :user => { :nickname => "Aldor", :email => "aldor@diesel.kg" } }

      user = User.find_by(:email => "aldor@diesel.kg")
      expect(user).to be_present

      expect(response.status).to eq(200)
      # The password is the point. Read it back off the record's own digest
      # rather than guessing: whatever string is on screen must be the one
      # that actually authenticates.
      shown = response.body[%r{<code class="generated-password">([^<]+)</code>}, 1]
      expect(shown).to be_present
      expect(user.authenticate(shown)).to be_truthy
    end

    it "does not let that page be cached" do
      break_smtp!

      post users_path, :params => { :user => { :nickname => "Aldor", :email => "aldor@diesel.kg" } }

      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "still signs the user in" do
      break_smtp!

      post users_path, :params => { :user => { :nickname => "Aldor", :email => "aldor@diesel.kg" } }
      get dashboard_path

      expect(response.status).to eq(200)
    end

    it "redirects to the dashboard as usual when the letter goes out" do
      post users_path, :params => { :user => { :nickname => "Aldor", :email => "aldor@diesel.kg" } }

      expect(response).to redirect_to(dashboard_path)
    end

    it "never writes the generated password to the log" do
      break_smtp!
      logged = []
      allow(Rails.logger).to receive(:error) { |line| logged << line }

      post users_path, :params => { :user => { :nickname => "Aldor", :email => "aldor@diesel.kg" } }

      shown = response.body[%r{<code class="generated-password">([^<]+)</code>}, 1]
      expect(logged.join("\n")).not_to include(shown)
      expect(logged.join("\n")).to include("Net::SMTPAuthenticationError")
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rspec spec/requests/mail_failure_spec.rb
```

Expected: the four `break_smtp!` examples fail with `Net::SMTPAuthenticationError` escaping the
request. The "redirects to the dashboard as usual" example should already pass — it describes
today's behaviour and must keep passing throughout.

- [ ] **Step 3: Add the five i18n keys to all seven locale files**

Under the existing `users:` → `create:` block in each file (in `ru.yml` it begins at line 677 and
already holds `check_your_mail`), add a nested `mail_failed:` block.

`config/locales/ru.yml`:
```yaml
      mail_failed:
        title: "Аккаунт создан, но письмо не отправлено"
        explanation: "Мы не смогли отправить письмо с паролем — почтовая служба временно недоступна. Сохраните пароль сейчас: другого способа его узнать нет."
        password_label: "Ваш пароль"
        change_hint: "Смените его в профиле, когда будет удобно."
        continue: "Перейти в личный кабинет"
```

`config/locales/en.yml`:
```yaml
      mail_failed:
        title: "Account created, but we couldn't send the email"
        explanation: "We couldn't email you your password — the mail service is temporarily unavailable. Save it now: there is no other way to recover it."
        password_label: "Your password"
        change_hint: "Change it in your profile whenever convenient."
        continue: "Go to my dashboard"
```

`config/locales/uk.yml`:
```yaml
      mail_failed:
        title: "Обліковий запис створено, але лист не надіслано"
        explanation: "Ми не змогли надіслати лист із паролем — поштова служба тимчасово недоступна. Збережіть пароль зараз: іншого способу дізнатися його немає."
        password_label: "Ваш пароль"
        change_hint: "Змініть його в профілі, коли буде зручно."
        continue: "Перейти до особистого кабінету"
```

`config/locales/be.yml`:
```yaml
      mail_failed:
        title: "Уліковы запіс створаны, але ліст не адпраўлены"
        explanation: "Мы не змаглі адправіць ліст з паролем — паштовая служба часова недаступная. Захавайце пароль зараз: іншага спосабу даведацца яго няма."
        password_label: "Ваш пароль"
        change_hint: "Змяніце яго ў профілі, калі будзе зручна."
        continue: "Перайсці ў асабісты кабінет"
```

`config/locales/pl.yml`:
```yaml
      mail_failed:
        title: "Konto zostało utworzone, ale nie udało się wysłać wiadomości"
        explanation: "Nie mogliśmy wysłać wiadomości z hasłem — usługa pocztowa jest chwilowo niedostępna. Zapisz hasło teraz: nie ma innego sposobu, aby je odzyskać."
        password_label: "Twoje hasło"
        change_hint: "Zmień je w profilu, kiedy będzie wygodnie."
        continue: "Przejdź do panelu"
```

`config/locales/tr.yml`:
```yaml
      mail_failed:
        title: "Hesap oluşturuldu, ancak e-posta gönderilemedi"
        explanation: "Parolanızı içeren e-postayı gönderemedik — posta hizmeti geçici olarak kullanılamıyor. Parolayı şimdi kaydedin: başka bir yolla öğrenmeniz mümkün değil."
        password_label: "Parolanız"
        change_hint: "Uygun olduğunuzda profilinizden değiştirin."
        continue: "Kişisel sayfaya git"
```

`config/locales/ka.yml`:
```yaml
      mail_failed:
        title: "ანგარიში შეიქმნა, მაგრამ წერილი ვერ გაიგზავნა"
        explanation: "ვერ შევძელით პაროლის გამოგზავნა — საფოსტო სერვისი დროებით მიუწვდომელია. შეინახეთ პაროლი ახლავე: მისი გაგების სხვა გზა არ არსებობს."
        password_label: "თქვენი პაროლი"
        change_hint: "შეცვალეთ იგი პროფილში, როცა მოგესურვებათ."
        continue: "პირად კაბინეტში გადასვლა"
```

- [ ] **Step 4: Create the view**

Create `app/views/users/welcome_password.html.erb`:

```erb
<%# Rendered ONLY when the welcome letter could not be delivered.
    UsersController#create branches here instead of redirecting, because the
    generated password exists nowhere else -- not in the database (only its
    digest is), not in the log (deliberately), and not in the letter that just
    failed. Redirecting would destroy it.

    The account IS created and the session IS signed in by this point, so the
    "change it in your profile" advice is actionable: the user now holds the
    current password that app/views/users/edit.html.erb demands. That keeps the
    CWE-620 fix of 2026-08-07 intact rather than working around it.

    The controller sets Cache-Control: no-store on this response, because the
    body contains a live credential. %>
<h1><%= t("users.create.mail_failed.title") %></h1>

<p><%= t("users.create.mail_failed.explanation") %></p>

<p class="field">
  <strong><%= t("users.create.mail_failed.password_label") %>:</strong>
  <code class="generated-password"><%= @generated_password %></code>
</p>

<p><%= t("users.create.mail_failed.change_hint") %></p>

<p><%= link_to t("users.create.mail_failed.continue"), dashboard_path, :class => "btn btn--go" %></p>
```

- [ ] **Step 5: Change the controller**

In `app/controllers/users_controller.rb`, replace lines 74-80 (the `if @user.save` block) with:

```ruby
    if @user.save
      authenticate_user

      # MailDelivery.attempt returns false only on a TRANSPORT failure; a bug in
      # the mailer or a missing translation still raises. See
      # app/services/mail_delivery.rb.
      #
      # The else branch is unreachable from the acceptance suite:
      # config/environments/test.rb sets delivery_method = :test, which never
      # raises, so "Удачная регистрация" still redirects to the dashboard and
      # still sends exactly one letter. No feature file changes.
      if MailDelivery.attempt { send_welcome_letter_to(@user) }
        redirect_to dashboard_path
      else
        # The only surviving copy of this password. Do not redirect, do not log.
        @generated_password = generated_password
        response.headers["Cache-Control"] = "no-store"
        render :welcome_password
      end
    else
      render :new, status: :unprocessable_entity
    end
```

- [ ] **Step 6: Run the tests and verify they pass**

```bash
bundle exec rspec spec/requests/mail_failure_spec.rb spec/i18n_spec.rb
```

Expected: all pass. `spec/i18n_spec.rb` is included because it is what catches a key added to
`ru.yml` but forgotten in `en.yml`.

- [ ] **Step 7: Prove the frozen signup scenarios still pass**

```bash
bundle exec cucumber features/signup/signup.feature
```

Expected: 4 scenarios, 0 failures. If `Удачная регистрация` fails, stop — do not edit the feature.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/users_controller.rb app/views/users/welcome_password.html.erb \
        config/locales/*.yml spec/requests/mail_failure_spec.rb
git commit -m "Show the generated password on screen when the welcome letter fails"
```

---

## Task 3: Password reset keeps its identical response

**Files:**
- Modify: `app/controllers/password_resets_controller.rb:28-30`
- Test: `spec/requests/mail_failure_spec.rb` (append)

**Interfaces:**
- Consumes: `MailDelivery.attempt` from Task 1.
- Produces: no new interface. The return value is deliberately discarded.

- [ ] **Step 1: Write the failing test**

Append to `spec/requests/mail_failure_spec.rb`, inside the outer `describe`:

```ruby
  # THE important example in this file.
  #
  # PasswordResetsController#create sends only inside `if user`, so an SMTP
  # exception fires ONLY when the address is registered. Any failure response
  # that differs from the success response therefore answers the question
  # "is this address registered?" -- rebuilding exactly the oracle that
  # controller's identical-response design exists to prevent, and that
  # SessionsController#create refuses to answer at login.
  describe "password reset" do
    it "answers identically for a registered and an unregistered address" do
      break_smtp!
      user = create_user

      post password_resets_path, :params => { :email => user.email }
      registered = [response.status, response.location, flash[:notice]]

      post password_resets_path, :params => { :email => "nobody-at-all@example.com" }
      unregistered = [response.status, response.location, flash[:notice]]

      expect(registered).to eq(unregistered)
    end

    it "still issues the token, so a later retry can use it" do
      break_smtp!
      user = create_user

      post password_resets_path, :params => { :email => user.email }

      expect(user.reload.reset_password_token).to be_present
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rspec spec/requests/mail_failure_spec.rb -e "password reset"
```

Expected: FAIL — `Net::SMTPAuthenticationError` escapes on the registered address, so the two
responses differ (one is a 500).

- [ ] **Step 3: Change the controller**

In `app/controllers/password_resets_controller.rb`, replace lines 28-30:

```ruby
    if user
      token = user.issue_reset_password_token!
      # Return value DELIBERATELY DISCARDED, and this comment is why.
      #
      # This send happens only inside `if user`, so a transport failure here
      # occurs only for a registered address. Reporting it -- a different
      # flash, a different status, anything -- would tell the caller that the
      # address exists, which is the one thing this action is built not to
      # say (see the comment above #create, and sessions_controller.rb:24).
      # A dead SMTP server must look exactly like an unknown address.
      MailDelivery.attempt { NotificationMailer.password_reset(user, token).deliver_now }
    end
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
bundle exec rspec spec/requests/mail_failure_spec.rb
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/password_resets_controller.rb spec/requests/mail_failure_spec.rb
git commit -m "Keep password reset's response identical when SMTP is down"
```

---

## Task 4: Invitations report the failure to the actor

**Files:**
- Modify: `app/controllers/invitations_controller.rb` (lines 21, 37, 47, 76)
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/requests/mail_failure_spec.rb` (append)

**Interfaces:**
- Consumes: `MailDelivery.attempt` from Task 1.
- Produces: `#reject_rest_of_invitations` now **returns a Boolean** — `true` when every notification
  in the loop was delivered. Three i18n keys: `invitations.notice_sent_unnotified` (interpolates
  `%{nickname}`), `invitations.accept_unnotified`, `invitations.reject_unnotified`.

- [ ] **Step 1: Write the failing test**

Append to `spec/requests/mail_failure_spec.rb`, inside the outer `describe`:

```ruby
  describe "invitations" do
    def sign_in(user)
      put login_path, :params => { :email => user.email, :password => "1234" }
    end

    it "creates the invitation and says the email did not go out" do
      captain = create_user
      create_team(:captain => captain)
      player = create_user
      sign_in(captain)
      break_smtp!

      post invitations_path, :params => { :invitation => { :recepient_nickname => player.nickname } }

      expect(Invitation.count).to eq(1)
      expect(flash[:notice]).to eq(
        I18n.t("invitations.notice_sent_unnotified", :nickname => player.nickname, :locale => :ru)
      )
    end

    # The regression test for a bug that fixes itself. Before MailDelivery, the
    # mailer on line 37 raised, which skipped reject_rest_of_invitations
    # entirely: the player was on the team, and every OTHER captain who had
    # invited them kept a stale invitation and heard nothing.
    it "still auto-rejects the other invitations when the mailer fails" do
      player  = create_user
      team_a  = create_team(:captain => create_user)
      team_b  = create_team(:captain => create_user)
      invite_a = Invitation.create!(:to_team => team_a, :recepient_nickname => player.nickname)
      Invitation.create!(:to_team => team_b, :recepient_nickname => player.nickname)
      sign_in(player)
      break_smtp!

      post accept_invitation_path(invite_a)

      expect(Invitation.count).to eq(0)
      expect(player.reload.team).to eq(team_a)
      expect(flash[:alert]).to eq(I18n.t("invitations.accept_unnotified", :locale => :ru))
    end
  end
```

Both route helpers used above are verified against `bin/rails routes` (2026-08-25):
`accept_invitation` is `POST /invitations/accept/:id`, and `put login_path` reaches
`sessions#create` (both POST and PUT map there), matching the `sign_in` helper in
`spec/requests/locale_switcher_spec.rb`.

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rspec spec/requests/mail_failure_spec.rb -e "invitations"
```

Expected: FAIL. The first example fails on the missing translation; the second shows
`Invitation.count == 1`, proving the skipped loop.

- [ ] **Step 3: Add the three i18n keys to all seven locale files**

Under the existing top-level `invitations:` block (which already holds `notice_sent` and `new:`):

`ru.yml`:
```yaml
    notice_sent_unnotified: "Приглашение для %{nickname} создано, но письмо отправить не удалось"
    accept_unnotified: "Вы вступили в команду, но некоторые уведомления отправить не удалось"
    reject_unnotified: "Приглашение отклонено, но уведомление отправить не удалось"
```

`en.yml`:
```yaml
    notice_sent_unnotified: "Invitation for %{nickname} created, but the email could not be sent"
    accept_unnotified: "You joined the team, but some notifications could not be sent"
    reject_unnotified: "Invitation rejected, but the notification could not be sent"
```

`uk.yml`:
```yaml
    notice_sent_unnotified: "Запрошення для %{nickname} створено, але лист надіслати не вдалося"
    accept_unnotified: "Ви приєдналися до команди, але деякі сповіщення надіслати не вдалося"
    reject_unnotified: "Запрошення відхилено, але сповіщення надіслати не вдалося"
```

`be.yml`:
```yaml
    notice_sent_unnotified: "Запрашэнне для %{nickname} створана, але ліст адправіць не ўдалося"
    accept_unnotified: "Вы далучыліся да каманды, але некаторыя апавяшчэнні адправіць не ўдалося"
    reject_unnotified: "Запрашэнне адхілена, але апавяшчэнне адправіць не ўдалося"
```

`pl.yml` — note the deliberately genderless phrasing in `accept_unnotified`; "Dołączyłeś" would
address every player as masculine:
```yaml
    notice_sent_unnotified: "Zaproszenie dla gracza «%{nickname}» zostało utworzone, ale nie udało się wysłać wiadomości"
    accept_unnotified: "Dołączenie do drużyny powiodło się, ale nie udało się wysłać części powiadomień"
    reject_unnotified: "Zaproszenie zostało odrzucone, ale nie udało się wysłać powiadomienia"
```

`tr.yml` — the suffix rides on `oyuncu` ("player"), never on `%{nickname}`:
```yaml
    notice_sent_unnotified: "«%{nickname}» adlı oyuncu için davet oluşturuldu, ancak e-posta gönderilemedi"
    accept_unnotified: "Takıma katıldınız, ancak bazı bildirimler gönderilemedi"
    reject_unnotified: "Davet reddedildi, ancak bildirim gönderilemedi"
```

`ka.yml` — same treatment; `მოთამაშისთვის` ("for the player") carries the case:
```yaml
    notice_sent_unnotified: "მოთამაშისთვის სახელით «%{nickname}» მოწვევა შეიქმნა, მაგრამ წერილი ვერ გაიგზავნა"
    accept_unnotified: "გუნდს შეუერთდით, მაგრამ ზოგიერთი შეტყობინება ვერ გაიგზავნა"
    reject_unnotified: "მოწვევა უარყოფილია, მაგრამ შეტყობინება ვერ გაიგზავნა"
```

- [ ] **Step 4: Verify the Turkish placeholder rule with both name shapes**

```bash
bundle exec rails runner -e test '
  I18n.locale = :tr
  ["Aldor", "Ali"].each { |n| puts I18n.t("invitations.notice_sent_unnotified", :nickname => n) }'
```

Expected: both read naturally, because the suffix is on `oyuncu` and never touches the name. If one
reads oddly, the template is inflecting around the placeholder — rewrite it, do not proceed.

- [ ] **Step 5: Change the four call sites**

In `app/controllers/invitations_controller.rb`, `#create`:

```ruby
    if @invitation.save
      # Merb original: app/controllers/invitations.rb#send_invitation_notification.
      delivered = MailDelivery.attempt do
        NotificationMailer.invitation_notification(@invitation.for_user, @invitation.to_team).deliver_now
      end

      # Unlike password reset, there is no oracle to protect here: the captain
      # already knows who they invited. Silence would just leave them waiting
      # for a reply to a message that was never sent.
      key = delivered ? "invitations.notice_sent" : "invitations.notice_sent_unnotified"
      redirect_to new_invitation_path,
                  notice: t(key, nickname: @invitation.recepient_nickname)
    else
```

`#accept`:

```ruby
  def accept
    add_user_to_team_members
    @invitation.delete

    # Merb original: app/controllers/invitations.rb#send_accept_notification.
    delivered = MailDelivery.attempt do
      NotificationMailer.accept_notification(@invitation.for_user, @invitation.to_team).deliver_now
    end

    # `&`, not `&&`: this must NOT short-circuit. Before MailDelivery existed a
    # raise on the line above skipped this call entirely, leaving the join done
    # and every other captain holding a stale invitation, un-notified.
    delivered &= reject_rest_of_invitations

    # One flash for both mail operations, never one per failed recipient.
    if delivered
      redirect_to dashboard_path
    else
      redirect_to dashboard_path, alert: t("invitations.accept_unnotified")
    end
  end
```

`#reject`:

```ruby
  def reject
    @invitation.delete
    # Merb original: app/controllers/invitations.rb#send_reject_notification.
    delivered = MailDelivery.attempt do
      NotificationMailer.reject_notification(@invitation.for_user, @invitation.to_team).deliver_now
    end

    if delivered
      redirect_to dashboard_path
    else
      redirect_to dashboard_path, alert: t("invitations.reject_unnotified")
    end
  end
```

`#reject_rest_of_invitations` — keep the existing comment above it, and change the body so it
returns whether every notification got out:

```ruby
  def reject_rest_of_invitations
    all_delivered = true

    Invitation.for(current_user).each do |invitation|
      invitation.delete
      # `&=` so one captain's failed notification never stops the loop: the
      # invitations are deleted either way, and the caller reports a single
      # summary rather than one flash per recipient.
      all_delivered &= MailDelivery.attempt do
        NotificationMailer.reject_notification(invitation.for_user, invitation.to_team).deliver_now
      end
    end

    all_delivered
  end
```

- [ ] **Step 6: Run the tests and verify they pass**

```bash
bundle exec rspec spec/requests/mail_failure_spec.rb spec/i18n_spec.rb
bundle exec cucumber features/teams
```

Expected: all pass. The Cucumber run is here because invitations are how teams form, and those
scenarios drive the real controller.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/invitations_controller.rb config/locales/*.yml \
        spec/requests/mail_failure_spec.rb
git commit -m "Tell the captain when an invitation email could not be sent"
```

---

## Task 5: The SMTP probe script

**Files:**
- Create: `ops/smtp/probe.rb`
- Test: `spec/ops/smtp_probe_spec.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks. This file must **not** require Rails — it runs on a bare CI
  runner.
- Produces: `SMTPProbe.classify(results) # => Hash` with keys `"verdict"` (`"ok"` / `"degraded"` /
  `"down"`), `"summary"` (String), `"failures"` (Array of Hashes). And
  `SMTPProbe.check(role:, address:, port:, user_name:, password:) # => Hash` with keys `"role"`,
  `"configured"`, `"ok"`, and on failure `"error_class"` and `"error"`.

- [ ] **Step 1: Write the failing test**

Create `spec/ops/smtp_probe_spec.rb`:

```ruby
# frozen_string_literal: true

require "spec_helper"
require_relative "../../ops/smtp/probe"

# classify is a pure function: no network, no clock, no Rails. Same reasoning as
# spec/ops/vmscale_policy_spec.rb -- the shell (or in this case Net::SMTP) does
# the talking, the Ruby does the deciding, and only the deciding is tested here.
RSpec.describe SMTPProbe do
  def ok(role)         = { "role" => role, "configured" => true, "ok" => true }
  def broken(role)     = { "role" => role, "configured" => true, "ok" => false,
                           "error_class" => "Net::SMTPAuthenticationError",
                           "error" => "535 5.7.8 Username and Password not accepted" }
  def unconfigured(role) = { "role" => role, "configured" => false, "ok" => false }

  it "is ok when both endpoints authenticate" do
    expect(described_class.classify([ok("primary"), ok("spare")])["verdict"]).to eq("ok")
  end

  # The whole point of probing the spare. A fallback nobody exercises is not a
  # fallback -- it is a hope. This must be loud even while the site is fine.
  it "is degraded when the spare is broken but the primary works" do
    result = described_class.classify([ok("primary"), broken("spare")])

    expect(result["verdict"]).to eq("degraded")
    expect(result["failures"].map { |f| f["role"] }).to eq(["spare"])
  end

  it "is down when the primary is broken, even if the spare works" do
    expect(described_class.classify([broken("primary"), ok("spare")])["verdict"]).to eq("down")
  end

  it "is down when both are broken" do
    expect(described_class.classify([broken("primary"), broken("spare")])["verdict"]).to eq("down")
  end

  # So the workflow can be merged and start running BEFORE the Fastmail app
  # password exists. A permanently-red probe teaches everyone to ignore it.
  it "does not fail merely because the spare is not configured yet" do
    result = described_class.classify([ok("primary"), unconfigured("spare")])

    expect(result["verdict"]).to eq("ok")
    expect(result["summary"]).to include("spare not configured")
  end

  it "still reports down when the primary fails and no spare is configured" do
    expect(described_class.classify([broken("primary"), unconfigured("spare")])["verdict"]).to eq("down")
  end

  it "names the error class in the summary so the issue title is useful" do
    result = described_class.classify([broken("primary"), ok("spare")])

    expect(result["summary"]).to include("Net::SMTPAuthenticationError")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rspec spec/ops/smtp_probe_spec.rb
```

Expected: FAIL — `cannot load such file -- ops/smtp/probe`.

- [ ] **Step 3: Write the implementation**

Create `ops/smtp/probe.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# Proves that the app's SMTP credentials still authenticate -- and that the
# warm spare's do too -- without sending a single message.
#
# Nothing is ever delivered. A probe that mailed a real address to prove mail
# works would spend the sending reputation this whole design exists to protect.
#
# Split the same way ops/vmscale does it: `check` talks to the network, and
# `classify` is a pure function from results to a verdict, so the decision is
# testable from fixtures with no SMTP server anywhere.
#
# See docs/superpowers/specs/2026-08-25-smtp-outage-resilience-design.md §D7
# and docs/runbooks/smtp-failover.md.

require "net/smtp"
require "json"

module SMTPProbe
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 10
  MESSAGE_LIMIT = 200

  module_function

  # Connects, STARTTLS, AUTH, QUIT. Sends nothing.
  def check(role:, address:, port:, user_name:, password:)
    return { "role" => role, "configured" => false, "ok" => false } if
      address.to_s.empty? || user_name.to_s.empty? || password.to_s.empty?

    smtp = Net::SMTP.new(address, port.to_i)
    smtp.open_timeout = OPEN_TIMEOUT
    smtp.read_timeout = READ_TIMEOUT
    smtp.enable_starttls_auto

    smtp.start(address, user_name, password, :plain) { }
    { "role" => role, "configured" => true, "ok" => true }
  rescue StandardError => e
    # StandardError is correct HERE, unlike in MailDelivery: this script's only
    # job is to report what went wrong, and every failure mode is interesting.
    { "role" => role, "configured" => true, "ok" => false,
      "error_class" => e.class.to_s, "error" => e.message.to_s[0, MESSAGE_LIMIT] }
  end

  # Pure. results -> verdict.
  def classify(results)
    primary = results.find { |r| r["role"] == "primary" }
    spare   = results.find { |r| r["role"] == "spare" }

    failures = results.select { |r| r["configured"] && !r["ok"] }
    notes    = []
    notes << "spare not configured" if spare && !spare["configured"]

    verdict =
      if primary.nil? || !primary["ok"]
        "down"
      elsif spare && spare["configured"] && !spare["ok"]
        "degraded"
      else
        "ok"
      end

    summary =
      if failures.empty?
        (["all configured SMTP endpoints authenticate"] + notes).join("; ")
      else
        described = failures.map { |f| "#{f['role']}: #{f['error_class']} #{f['error']}" }
        (described + notes).join("; ")
      end

    { "verdict" => verdict, "summary" => summary, "failures" => failures }
  end
end

if $PROGRAM_NAME == __FILE__
  results = [
    SMTPProbe.check(role: "primary",
                    address:   ENV["SMTP_ADDRESS"] || "smtp.gmail.com",
                    port:      ENV["SMTP_PORT"] || 587,
                    user_name: ENV["SMTP_USERNAME"],
                    password:  ENV["SMTP_PASSWORD"]),
    SMTPProbe.check(role: "spare",
                    address:   ENV["SMTP_SPARE_ADDRESS"],
                    port:      ENV["SMTP_SPARE_PORT"] || 587,
                    user_name: ENV["SMTP_SPARE_USERNAME"],
                    password:  ENV["SMTP_SPARE_PASSWORD"])
  ]

  verdict = SMTPProbe.classify(results)
  puts JSON.pretty_generate(verdict)
  exit(verdict["verdict"] == "ok" ? 0 : 1)
end
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
bundle exec rspec spec/ops/smtp_probe_spec.rb
```

Expected: 7 examples, 0 failures.

- [ ] **Step 5: Confirm the script never sends and never leaks a password**

```bash
grep -n "send_message\|deliver\|sendmail" ops/smtp/probe.rb   # expect: no output
grep -n "password" ops/smtp/probe.rb                          # expect: only parameter plumbing
```

- [ ] **Step 6: Commit**

```bash
git add ops/smtp/probe.rb spec/ops/smtp_probe_spec.rb
git commit -m "Add an SMTP credential probe that authenticates without sending"
```

---

## Task 6: The scheduled probe workflow

**Files:**
- Create: `.github/workflows/smtp-probe.yml`

**Interfaces:**
- Consumes: `ops/smtp/probe.rb` from Task 5, exit code 0 (ok) or 1 (degraded/down).
- Produces: a GitHub issue labelled `smtp` when the verdict is not `ok`.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/smtp-probe.yml`:

```yaml
# Proves the SMTP credentials still authenticate -- the live one AND the warm
# spare -- without sending any mail. See
# docs/superpowers/specs/2026-08-25-smtp-outage-resilience-design.md §D7.
#
# Six-hourly, not every fifteen minutes, and that is a deliberate trade: each
# run performs a real AUTH from a GitHub runner IP, which is itself mildly
# provocative to Gmail. Connect-only would avoid it but would not detect a
# revoked app password, which is the failure being hunted.
#
# The spare is probed on every run even while the primary is healthy. An idle
# fallback that nobody exercises is not a fallback.
name: SMTP probe

on:
  schedule:
    - cron: "17 */6 * * *"
  workflow_dispatch:

permissions:
  contents: read
  issues: write

jobs:
  probe:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.3.12"

      - name: Probe both endpoints
        id: probe
        continue-on-error: true
        env:
          SMTP_ADDRESS: smtp.gmail.com
          SMTP_PORT: "587"
          SMTP_USERNAME: ${{ secrets.SMTP_USERNAME }}
          SMTP_PASSWORD: ${{ secrets.SMTP_PASSWORD }}
          SMTP_SPARE_ADDRESS: ${{ secrets.SMTP_SPARE_ADDRESS }}
          SMTP_SPARE_PORT: "587"
          SMTP_SPARE_USERNAME: ${{ secrets.SMTP_SPARE_USERNAME }}
          SMTP_SPARE_PASSWORD: ${{ secrets.SMTP_SPARE_PASSWORD }}
        run: |
          set +e
          ruby ops/smtp/probe.rb > verdict.json
          echo "exit_code=$?" >> "$GITHUB_OUTPUT"
          cat verdict.json

      - name: File an issue when the verdict is not ok
        if: steps.probe.outputs.exit_code != '0'
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const verdict = JSON.parse(fs.readFileSync('verdict.json', 'utf8'));
            const title = `SMTP probe: ${verdict.verdict} — ${verdict.summary}`.slice(0, 200);
            const body = [
              '```json',
              JSON.stringify(verdict, null, 2),
              '```',
              '',
              'Cutover procedure: `docs/runbooks/smtp-failover.md`.',
              '',
              'A `degraded` verdict means the SITE IS FINE but the warm spare',
              'does not authenticate — fix it before it is needed, not after.',
            ].join('\n');
            await github.rest.issues.create({
              owner: context.repo.owner,
              repo: context.repo.repo,
              title,
              body,
              labels: ['smtp'],
            });

      - name: Fail the run so the badge reflects reality
        if: steps.probe.outputs.exit_code != '0'
        run: exit 1
```

- [ ] **Step 2: Validate the YAML parses**

```bash
ruby -ryaml -e 'YAML.safe_load_file(".github/workflows/smtp-probe.yml", aliases: true); puts "yaml ok"'
```

Expected: `yaml ok`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/smtp-probe.yml
git commit -m "Run the SMTP probe every six hours and file an issue on failure"
```

- [ ] **Step 4: Dispatch it once after merge, and read the output**

This step needs the branch merged (scheduled workflows only run from the default branch).

```bash
gh workflow run "SMTP probe"
sleep 45 && gh run list --workflow "SMTP probe" --limit 1
```

Expected before the Fastmail secrets exist: verdict `ok`, summary ending `spare not configured`.
That is correct, not a bug — see Task 5, Step 1.

---

## Task 7: The failover runbook and the documentation gates

**Files:**
- Create: `docs/runbooks/smtp-failover.md`
- Modify: `CLAUDE.md`
- Modify: `config/deploy.yml` (comment only)

**Interfaces:**
- Consumes: everything above.
- Produces: no code interface.

- [ ] **Step 1: Write the runbook**

Create `docs/runbooks/smtp-failover.md` covering, in order:

1. **Symptoms** — an `SMTP probe` issue; `[mail] delivery failed:` lines in `docker logs`; users
   reporting no welcome letter. Note that the *site keeps working* now: signups succeed and show the
   password on screen, invitations succeed with a warning flash.
2. **Decide** — `degraded` means fix the spare, do not cut over. `down` means cut over.
3. **Cut over** — update the `SMTP_USERNAME` and `SMTP_PASSWORD` GitHub secrets to the spare's
   values; change the one `SMTP_ADDRESS` line in `config/deploy.yml` to `smtp.fastmail.com`; commit;
   dispatch the deploy workflow. Record that `MAIL_FROM` is derived from `SMTP_USERNAME` in
   `.kamal/secrets`, so there is no second place to change — and that after cutover the From address
   becomes an `@mezin.eu` address, which `mezin.eu`'s SPF already authorises.
4. **Verify** — dispatch the SMTP probe; register a throwaway account and confirm the letter arrives.
5. **Cut back** — the same steps in reverse.
6. **What this does not cover** — a per-recipient 550 (the probe never sends, so it cannot see one).

- [ ] **Step 2: Add the comment to `config/deploy.yml`**

Above the `SMTP_ADDRESS` line, add:

```yaml
    # Changing this host is step 3 of docs/runbooks/smtp-failover.md. The warm
    # spare is Fastmail (smtp.fastmail.com) -- proven on every run of the SMTP
    # probe workflow, never used by the app until someone cuts over.
```

- [ ] **Step 3: Recount the i18n leaves and update `CLAUDE.md`**

```bash
ruby -ryaml -e 'def leaves(h,p="") h.flat_map { |k,v| v.is_a?(Hash) ? leaves(v,"#{p}#{k}.") : ["#{p}#{k}"] } end
               puts leaves(YAML.unsafe_load_file("config/locales/ru.yml")["ru"]).size'
```

Write down **what it prints**. Do not compute `1001 + 8`. That entry has gone stale six times, twice
on the day it was written, which is why it is measured.

Then update the i18n bullet in `CLAUDE.md` with the measured number and today's date, and add a
short subsection under Testing recording the mail-failure policy: `MailDelivery` rescues transport
errors only; password reset discards its return value deliberately; the signup failure page shows
the generated password once.

- [ ] **Step 4: Run the full gates**

Run these yourself — do not dispatch them to a subagent.

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
bin/rails zeitwerk:check
```

Expected: RSpec green (the count will have risen — measure it, do not quote the old one). Cucumber
green.

- [ ] **Step 5: Prove the inherited acceptance contract is untouched**

```bash
git ls-tree -r --name-only d035146 | grep '\.feature$' | sort > /tmp/inherited
git ls-files 'features/**/*.feature' | sort > /tmp/current
bundle exec cucumber $(comm -12 /tmp/inherited /tmp/current | tr '\n' ' ')
```

Expected: **228 scenarios (226 passed, 2 undefined) / 2325 steps.** Any other number means a feature
file changed — stop and report; do not adjust the feature.

- [ ] **Step 6: Confirm no `.feature` file was touched**

```bash
git diff --stat master -- 'features/**/*.feature'
```

Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add docs/runbooks/smtp-failover.md config/deploy.yml CLAUDE.md
git commit -m "Document SMTP failover and the mail-failure policy"
```

---

## Task 8: Provision and rehearse the spare (operator, not agent)

**Files:** none. This task is performed by the repository owner.

**Interfaces:**
- Consumes: Tasks 5-7 merged.
- Produces: three GitHub secrets — `SMTP_SPARE_ADDRESS` (`smtp.fastmail.com`),
  `SMTP_SPARE_USERNAME`, `SMTP_SPARE_PASSWORD`.

- [ ] **Step 1: Create a Fastmail app password** scoped to SMTP only.

- [ ] **Step 2: Add the three repository secrets.** Values go in the secret store and nowhere else —
      not into a config file, not into a transcript, not into a commit.

- [ ] **Step 3: Dispatch the probe and confirm the verdict moves from `ok` (spare not configured) to
      plain `ok` with both endpoints authenticating.**

```bash
gh workflow run "SMTP probe"
```

- [ ] **Step 4: Rehearse the cutover for real.** Follow `docs/runbooks/smtp-failover.md` end to end:
      switch to Fastmail, register a throwaway account, confirm the letter arrives from an
      `@mezin.eu` address, then cut back. Roughly ten minutes; the blast radius is outbound mail
      only.

- [ ] **Step 5: Record the rehearsal date in the runbook.** An untested fallback and a tested one
      look identical in git; the date is the difference.

---

## Self-Review Notes

Checked against the spec, 2026-08-25:

- **Spec coverage:** D1→Task 1; D2→Task 1; D3→Task 2; D4→Task 3; D5→Task 4; D6→Tasks 6-7; D7→Tasks
  5-6; D8→Tasks 7-8. §2 (frozen features)→Task 2 Step 7 and Task 7 Steps 5-6. §4 (i18n)→Tasks 2 and
  4, recount in Task 7 Step 3. §5 (testing)→Tasks 1-5. §6 (rehearsal)→Task 8. §9 invariants→Task 7
  Steps 4-6.
- **Type consistency:** `MailDelivery.attempt` returns a Boolean everywhere; `classify`/`check`
  key names match between `ops/smtp/probe.rb` and `spec/ops/smtp_probe_spec.rb`;
  `reject_rest_of_invitations` returns a Boolean in both its definition and its caller.
- **Placeholder scan:** clean. The one assumed identifier (`accept_invitation_path`) was resolved
  against `bin/rails routes` before this plan was committed, along with the `put login_path` verb.
