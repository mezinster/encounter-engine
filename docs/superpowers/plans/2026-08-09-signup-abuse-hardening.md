# Signup and Password-Reset Abuse Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop an unauthenticated script from using `/signup` and `/password` as free outbound-mail
cannons, with limits a superadmin can change without a deploy, and make the reset flow issue its new
password only after a deliberate confirmation.

**Architecture:** A `:memory_store` cache backs a small hand-rolled fixed-window throttle whose limits
live in a `settings` table and are edited from the admin console. Signup additionally carries a
CSS-hidden honeypot field. The reset flow keeps its existing token but replaces the choose-your-own-
password form with a confirmation button that generates a password and mails it separately.

**Tech Stack:** Rails 8.0.5.1, Ruby 3.3.12 (rbenv), Postgres in production / sqlite in dev+test,
Puma single-process behind kamal-proxy, RSpec + Cucumber.

## Global Constraints

- Ruby is **not on `PATH` in non-login shells**. Every command must be prefixed with:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **NEVER edit any file under `features/` ending in `.feature`.** No scenario in the frozen contract
  exercises password reset (verified: no feature references `password/new`, `Восстановление`, `забыл`
  or `сброс`), but several exercise signup and login. If any goes red, STOP and report.
- New user-facing strings go in **all four** of `config/locales/{ru,en,uk,ka}.yml`. `spec/i18n_spec.rb`
  enforces exact `ru`↔`en` leaf parity and **fails on duplicate YAML keys** — add keys inside existing
  blocks, never create a second block with the same name.
- Specs asserting a user-facing message must assert the **literal Russian string**, never
  `I18n.t(key)`: a missing key degrades both sides of that comparison to the same
  `translation missing:` text, so the `t()` form passes with the locale entry deleted.
- Hash rockets (`:key => value`) throughout, including for symbol keys. Russian for user-facing
  strings, English for code and comments.
- **Mutation-test every guard-style assertion**: break the guard, confirm the test goes red, restore.
  A green suite has repeatedly been weak evidence in this repository.
- **Implementers cannot run Cucumber** — their Bash tool times out at 120s and the suite needs ~4
  minutes. Run RSpec, stop before committing, and report. The controller runs Cucumber.
- Per-task expectations below are stated as **deltas**, not absolute counts. The absolute number
  moves whenever master does -- it was quoted as 1128 while this plan was being written and measured
  **1164** on the branch a few hours later, because PR #58 landed in between. **0 failures is the
  binding check**; the delta is there so a silently-skipped spec file is visible. If your delta
  differs, find out why rather than adjusting the number.
- Baselines, re-measured on `feature/signup-abuse-hardening` on 2026-08-09:
  **RSpec 1164 examples / 0 failures / 6 pending**;
  **Cucumber 232 scenarios (2 undefined, 230 passed) / 2342 steps** (this one has been stable for
  days and is the reliable figure).
- Production is a single Puma process in a single container (there is no `config/puma.rb` and no
  `WEB_CONCURRENCY` in `config/deploy.yml`). The whole `:memory_store` decision rests on that; it is
  recorded in the config comment in Task 1 and must not be quietly invalidated.

---

## Decision to confirm before Task 6

The owner asked for "password reset link, after clicking the randomly generated password is sent in a
second email", to avoid a stranger being able to lock a user out.

**The anti-lockout property already holds today.** `PasswordResetsController#create` only issues a
token and mails a link; it never changes the password. A stranger who submits someone else's address
achieves nothing but one email. So the current flow is *not* the "sends a new password directly"
design being rejected — it is already a link flow, and it ends in a form where the user chooses their
own password.

The change specified therefore trades:

- **Gains:** the user does not have to invent a password; consistent with signup, which also generates.
- **Costs:** the password travels in cleartext email (this is open follow-up-queue item #10, which
  wanted the opposite direction); two emails per reset instead of one, doubling the mail volume of the
  endpoint this plan is otherwise hardening; and the user must then change the generated password,
  which the profile form requires the current password for.

Task 6 implements exactly what was asked. If the owner would rather keep the existing
choose-your-own-password form, Task 6 is the only task to drop — every other task stands alone.

**One thing Task 6 must not do:** make the emailed link itself perform the reset. A `GET` that
changes state is prefetched by mail scanners (Outlook Safe Links and similar follow every link on
delivery), which would silently reissue a password no one asked for. The link lands on a confirmation
page; a `POST` from a button does the work.

---

## File Structure

**Created:**
- `db/migrate/20260809120000_create_settings.rb` — the settings table.
- `app/models/setting.rb` — name/value integer settings with in-code defaults.
- `app/controllers/concerns/request_throttling.rb` — the fixed-window throttle.
- `app/controllers/admin/settings_controller.rb` — superadmin edit surface.
- `app/views/admin/settings/show.html.erb` — the form.
- `app/views/notification_mailer/password_issued.text.erb` — the second reset email.
- `spec/models/setting_spec.rb`, `spec/requests/throttling_spec.rb`,
  `spec/requests/signup_honeypot_spec.rb`, `spec/requests/admin_settings_spec.rb`.

**Modified:**
- `config/environments/production.rb`, `config/environments/test.rb` — cache store.
- `spec/rails_helper.rb` — clear the cache between examples.
- `app/controllers/users_controller.rb` — honeypot + throttle.
- `app/controllers/password_resets_controller.rb` — throttle + new confirm/issue flow.
- `app/views/users/new.html.erb` — the honeypot field.
- `app/views/password_resets/edit.html.erb` — confirmation button replaces the password form.
- `app/mailers/notification_mailer.rb` — `password_issued`.
- `public/stylesheets/components.css` — the honeypot hiding rule.
- `config/routes.rb` — admin settings, reset issue verb.
- `config/locales/{ru,en,uk,ka}.yml` — new keys.
- `app/views/admin/dashboard/show.html.erb` — link to settings.
- `features/support/env.rb` — clear the throttle cache between scenarios (support file, not a
  `.feature` — permitted).
- `spec/requests/password_reset_spec.rb` — rewritten for the new flow.
- `docs/security/2026-08-08-follow-up-queue.md` — close/annotate the relevant items.

---

## Task 1: Cache store, and proving `remote_ip` is real behind the proxy

**Files:**
- Modify: `config/environments/production.rb`
- Modify: `config/environments/test.rb`
- Modify: `spec/rails_helper.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: a working `Rails.cache` in production and test that supports
  `#increment(key, amount, expires_in:)`, and a per-example cache reset so throttle specs cannot leak
  counters into each other.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/throttling_spec.rb` with just this for now:

```ruby
require "rails_helper"

describe "the cache backing request throttling", type: :request do
  it "counts with increment and expires the key" do
    key = "throttle:spec:1.2.3.4:0"

    expect(Rails.cache.increment(key, 1, :expires_in => 60.seconds)).to eq(1)
    expect(Rails.cache.increment(key, 1, :expires_in => 60.seconds)).to eq(2)
    expect(Rails.cache.read(key)).to eq(2)
  end

  # Without this the first throttle spec to run leaves a counter behind and the
  # second one starts mid-window -- a failure that only appears when the suite
  # is run in a different order.
  it "starts every example with an empty cache" do
    expect(Rails.cache.read("throttle:spec:1.2.3.4:0")).to be_nil
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/throttling_spec.rb
```

Expected: FAIL. The test environment has no `cache_store` configured, so `Rails.cache` is a
`NullStore` and `increment` returns `nil` rather than `1`.

- [ ] **Step 3: Configure the cache store in production**

In `config/environments/production.rb`, next to the other `config.` lines:

```ruby
  # In-process, deliberately. This instance runs ONE Puma process in ONE
  # container -- there is no config/puma.rb and no WEB_CONCURRENCY in
  # config/deploy.yml -- so a process-local store is shared by every request
  # thread, which is all the rate limiter needs.
  #
  # The assumption is the whole justification, so it is written down: the day
  # this app gains `workers` or a second server, each process gets its own
  # counters and every configured limit silently multiplies by the process
  # count. That failure is invisible -- limits still "work", just N times
  # weaker. Changing either of those things means moving to a shared store
  # (a Redis/Valkey Kamal accessory is the clean option; solid_cache would put
  # cache churn into the WAL that wal-g ships to Azure Blob, which lengthens
  # restore replay -- see docs/runbooks/restore.md).
  #
  # Nothing else in this app caches (`Rails.cache` appears nowhere else), so
  # 32MB is generous.
  config.cache_store = :memory_store, { :size => 32.megabytes }
```

- [ ] **Step 4: Configure the cache store in test**

In `config/environments/test.rb`:

```ruby
  # Real store, not :null_store: the throttle specs assert on counters, and a
  # null store silently returns nil from #increment, which would make every
  # one of them pass by never throttling anything.
  config.cache_store = :memory_store
```

- [ ] **Step 5: Clear the cache between examples**

In `spec/rails_helper.rb`, inside the existing `RSpec.configure do |config|` block:

```ruby
  # Throttle counters are process-global, unlike the database, which rolls back.
  # Without this the first example to trip a limit leaves the counter set and a
  # later example starts mid-window -- an order-dependent failure.
  config.before(:each) { Rails.cache.clear }
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/throttling_spec.rb
```

Expected: PASS, 2 examples.

- [ ] **Step 7: Mutation-test the cache clearing**

Comment out the `config.before(:each) { Rails.cache.clear }` line and re-run the file. The second
example must FAIL (it will read `2`, left by the first). Restore the line and confirm green again.
Record what you saw in the report — a spec that cannot fail is worth nothing.

- [ ] **Step 8: Run the full suite**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
```

Expected: baseline **+2**. Any *other* example that
changes behaviour here is a real finding: it would mean something depended on `Rails.cache` being a
no-op. Report it rather than adapting the test.

- [ ] **Step 9: Write down the remote_ip verification procedure**

This cannot be verified from a spec — it depends on kamal-proxy. Add this comment block directly
above the `cache_store` lines in `config/environments/production.rb` so it is found by whoever next
touches throttling:

```ruby
  # The limiter keys on request.remote_ip. Behind kamal-proxy every connection
  # arrives from the proxy container, and remote_ip is only correct if
  # ActionDispatch::RemoteIp trusts that hop and reads X-Forwarded-For. It
  # should: the proxy connects over the Docker bridge (a private address), and
  # Rails trusts private ranges by default.
  #
  # "Should" is not evidence, and the failure mode is the dangerous direction:
  # if XFF is ignored, EVERY request looks like one client and the first five
  # signups lock out the whole internet. Task 1 Step 9 of
  # docs/superpowers/plans/2026-08-09-signup-abuse-hardening.md records how to
  # verify it against the running proxy after deploy.
```

The procedure itself (run it after this plan's PR is deployed, not during implementation):

1. From a machine with a known public IP, `curl -i -X POST https://game.mezin.eu/password -d 'email=nobody@example.com'` repeatedly until the limit trips.
2. `ssh mezin 'docker logs --tail 200 $(docker ps -q --filter name=encounter-engine-web)'` and find the
   `[throttle]` line added in Task 3.
3. It prints both `remote_ip=` and `xff=`. **Pass:** `remote_ip` equals your public IP. **Fail:** it
   is a `172.x`/`10.x` address, or equals the proxy's — in which case set
   `config.action_dispatch.trusted_proxies` explicitly and re-test before relying on the limiter.

- [ ] **Step 10: Commit**

```bash
git add config/environments/production.rb config/environments/test.rb spec/rails_helper.rb spec/requests/throttling_spec.rb
git commit -m "Give the app a real cache store, for rate limiting"
```

---

## Task 2: The `Setting` model

**Files:**
- Create: `db/migrate/20260809120000_create_settings.rb`
- Create: `app/models/setting.rb`
- Create: `spec/models/setting_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Setting::DEFAULTS` — a frozen `Hash<String, Integer>` with keys `"signup_max"`,
    `"signup_window_seconds"`, `"reset_max"`, `"reset_window_seconds"`.
  - `Setting.integer(name) -> Integer` — the stored value, or the default when no row exists.
  - `Setting.put(name, value) -> Setting` — upsert, raises `ActiveRecord::RecordInvalid` on a bad name
    or a negative value.

- [ ] **Step 1: Write the failing test**

Create `spec/models/setting_spec.rb`:

```ruby
require "rails_helper"

describe Setting do
  it "falls back to the in-code default when no row exists" do
    expect(Setting.count).to eq(0)
    expect(Setting.integer("signup_max")).to eq(Setting::DEFAULTS.fetch("signup_max"))
  end

  it "prefers a stored value over the default" do
    Setting.put("signup_max", 42)
    expect(Setting.integer("signup_max")).to eq(42)
  end

  it "updates in place rather than adding a second row for the same name" do
    Setting.put("signup_max", 42)
    Setting.put("signup_max", 7)

    expect(Setting.where(:name => "signup_max").count).to eq(1)
    expect(Setting.integer("signup_max")).to eq(7)
  end

  # Zero is the documented "off" value, so it must survive validation --
  # a greater_than(0) rule here would remove the operator's ability to
  # disable a limit without a deploy.
  it "accepts zero" do
    Setting.put("reset_max", 0)
    expect(Setting.integer("reset_max")).to eq(0)
  end

  it "refuses a negative value" do
    expect { Setting.put("reset_max", -1) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  # Without this an admin form typo creates a row nothing reads, and the limit
  # silently stays at its default while the console shows the new number.
  it "refuses a name that is not a known setting" do
    expect { Setting.put("signup_maxx", 5) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/setting_spec.rb
```

Expected: FAIL with `uninitialized constant Setting`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260809120000_create_settings.rb`:

```ruby
class CreateSettings < ActiveRecord::Migration[8.0]
  # Name/value rather than one column per setting: the set of knobs will grow,
  # and a column per knob means a migration and a deploy for each one -- which
  # is exactly the deploy this feature exists to avoid.
  def change
    create_table :settings do |t|
      t.string  :name,  :null => false
      t.integer :value, :null => false
      t.timestamps
    end

    add_index :settings, :name, :unique => true
  end
end
```

- [ ] **Step 4: Run the migration**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails db:migrate && bin/rails db:test:prepare
```

If the sandbox refuses `db:migrate`, **STOP and report**. Do NOT hand-edit `db/schema.rb` — that
bypass happened during earlier security work and had to be disclosed in a PR.

- [ ] **Step 5: Write the model**

Create `app/models/setting.rb`:

```ruby
# -*- encoding : utf-8 -*-
#
# Operator-tunable numbers that must be changeable without a deploy.
#
# Defaults live here rather than as seed rows so a fresh database, a restored
# one, and a test transaction all behave identically -- and so deleting a row
# is a safe way back to the shipped value.
class Setting < ApplicationRecord
  DEFAULTS = {
    # Per client IP, per window. 0 disables the limit entirely.
    "signup_max"            => 5,
    "signup_window_seconds" => 3600,
    "reset_max"             => 3,
    "reset_window_seconds"  => 3600
  }.freeze

  validates :name, :presence => true, :uniqueness => true,
                   :inclusion => { :in => DEFAULTS.keys }
  validates :value, :numericality => { :only_integer => true,
                                       :greater_than_or_equal_to => 0 }

  def self.integer(name)
    find_by(:name => name)&.value || DEFAULTS.fetch(name)
  end

  def self.put(name, value)
    record = find_or_initialize_by(:name => name)
    record.value = value
    record.save!
    record
  end
end
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/setting_spec.rb
```

Expected: PASS, 6 examples.

- [ ] **Step 7: Mutation-test the two validations**

- Change `:greater_than_or_equal_to => 0` to `:greater_than => 0`. The "accepts zero" example must go
  RED. Restore.
- Delete the `:inclusion` clause. The "refuses a name that is not a known setting" example must go
  RED. Restore.

Both must fail for the right reason. Record the output in your report.

- [ ] **Step 8: Full suite, then commit**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
git add db/migrate/20260809120000_create_settings.rb db/schema.rb app/models/setting.rb spec/models/setting_spec.rb
git commit -m "Add operator-tunable settings, with in-code defaults"
```

Expected: baseline **+8** (2 from Task 1, 6 here).

---

## Task 3: The throttle, applied to both mail-sending endpoints

**Files:**
- Create: `app/controllers/concerns/request_throttling.rb`
- Modify: `app/controllers/users_controller.rb` (`#create`)
- Modify: `app/controllers/password_resets_controller.rb` (`#create`)
- Modify: `config/locales/{ru,en,uk,ka}.yml`
- Modify: `spec/requests/throttling_spec.rb`

**Interfaces:**
- Consumes: `Setting.integer(name)` from Task 2; a working `Rails.cache` from Task 1.
- Produces: `#throttle!(name) -> true | false` — private, available in any controller that includes
  `RequestThrottling`. `true` means "under the limit, proceed"; `false` means the caller must refuse.
  `name` is the prefix of the two settings, i.e. `"signup"` or `"reset"`.

- [ ] **Step 1: Write the failing tests**

Replace the contents of `spec/requests/throttling_spec.rb` with:

```ruby
require "rails_helper"

describe "throttling the endpoints that send mail", type: :request do
  # The cache is process-global and cleared per example by rails_helper.

  describe "signup" do
    def sign_up(nickname)
      post users_path, :params => { :user => { :nickname => nickname,
                                               :email => "#{nickname}@example.com" } }
    end

    it "allows submissions up to the configured limit" do
      Setting.put("signup_max", 3)

      expect {
        3.times { |i| sign_up("user#{i}") }
      }.to change { User.count }.by(3)
    end

    it "refuses the one past the limit, creating no user and sending no mail" do
      Setting.put("signup_max", 2)
      2.times { |i| sign_up("early#{i}") }

      expect {
        expect {
          sign_up("late")
        }.not_to change { User.count }
      }.not_to change { ActionMailer::Base.deliveries.size }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include("Слишком много попыток")
    end

    # 0 is the documented "off" switch and an operator will reach for it in an
    # incident. If it read as "allow nothing" the console would brick signup.
    it "treats a limit of zero as disabled, not as blocking everything" do
      Setting.put("signup_max", 0)

      expect { 6.times { |i| sign_up("many#{i}") } }.to change { User.count }.by(6)
    end

    it "counts per client address, so one abuser does not lock out everyone" do
      Setting.put("signup_max", 1)

      post users_path, :params => { :user => { :nickname => "a", :email => "a@example.com" } },
                       :headers => { "REMOTE_ADDR" => "203.0.113.10" }

      expect {
        post users_path, :params => { :user => { :nickname => "b", :email => "b@example.com" } },
                         :headers => { "REMOTE_ADDR" => "203.0.113.11" }
      }.to change { User.count }.by(1)
    end
  end

  describe "password reset" do
    # create_user takes NO arguments (spec/spec_helpers/fixtures_helper.rb:18)
    # -- it generates its own nickname and email. Passing a hash raises
    # ArgumentError.
    let!(:user) { create_user }

    it "refuses past the limit and sends no further mail" do
      Setting.put("reset_max", 2)
      2.times { post password_resets_path, :params => { :email => user.email } }

      expect {
        post password_resets_path, :params => { :email => user.email }
      }.not_to change { ActionMailer::Base.deliveries.size }

      expect(response).to have_http_status(:too_many_requests)
    end

    # The refusal must not become an oracle: the un-throttled path deliberately
    # answers identically for a registered and an unregistered address
    # (password_resets_controller.rb), and a throttle that only counted real
    # users would undo that.
    it "throttles an unregistered address the same way" do
      Setting.put("reset_max", 1)
      post password_resets_path, :params => { :email => "nobody@example.com" }

      post password_resets_path, :params => { :email => "nobody@example.com" }
      expect(response).to have_http_status(:too_many_requests)
    end
  end
end
```

- [ ] **Step 2: Run them and watch them fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/throttling_spec.rb
```

Expected: FAIL — every example that expects `:too_many_requests` gets a `302`, because nothing
throttles yet.

- [ ] **Step 3: Write the concern**

Create `app/controllers/concerns/request_throttling.rb`:

```ruby
# -*- encoding : utf-8 -*-
#
# A fixed-window per-IP counter for the two unauthenticated endpoints that send
# mail. Both hand an attacker-chosen address to the SMTP account configured in
# config/environments/production.rb (Gmail by default, which suspends senders
# that trip its spam heuristics) and both deliver synchronously, so each request
# also holds a Puma thread for the length of an SMTP round trip.
#
# NOT Rails 8's built-in `rate_limit`. That macro captures `to:` and `within:`
# when the controller class is loaded, so its numbers are fixed until the next
# deploy -- and the requirement here is that a superadmin can change them from
# the console during an incident (see Admin::SettingsController).
#
# Fixed window, not sliding: a client can burst up to 2x the limit across a
# window boundary. That is a known and accepted property. The alternative costs
# a sorted set per client, and this is a spam brake, not a security boundary.
module RequestThrottling
  extend ActiveSupport::Concern

  private

  # Returns true when the request is under the limit and may proceed.
  def throttle!(name)
    limit = Setting.integer("#{name}_max")
    # 0 disables. Checked before anything is written, so a disabled limit costs
    # no cache traffic at all.
    return true if limit.zero?

    window = Setting.integer("#{name}_window_seconds")
    bucket = Time.now.to_i / window
    key    = "throttle:#{name}:#{request.remote_ip}:#{bucket}"

    # MemoryStore#increment initialises a missing key, but the fallback is kept
    # so this concern does not silently stop counting if the store is ever
    # swapped for one that returns nil instead.
    count = Rails.cache.increment(key, 1, :expires_in => window.seconds + 1.minute)
    if count.nil?
      Rails.cache.write(key, 1, :expires_in => window.seconds + 1.minute)
      count = 1
    end

    return true if count <= limit

    # Both values, deliberately: this line is the evidence for the
    # remote_ip-behind-kamal-proxy check in Task 1 Step 9. If remote_ip is a
    # private address while xff carries the real one, the limiter is keying on
    # the proxy and is treating the whole internet as one client.
    Rails.logger.warn(
      "[throttle] #{name} over limit: remote_ip=#{request.remote_ip} " \
      "xff=#{request.headers['X-Forwarded-For'].inspect} " \
      "count=#{count} limit=#{limit} window=#{window}s"
    )
    false
  end
end
```

- [ ] **Step 4: Apply it to signup**

In `app/controllers/users_controller.rb`, add the include below the class declaration:

```ruby
class UsersController < ApplicationController
  include RequestThrottling
```

and make `#create` refuse first. The throttle check goes at the very top of the method, before
`User.new`:

```ruby
  def create
    # Before anything is built or saved: a refused request must cost this
    # server as little as it costs the client.
    unless throttle!("signup")
      @user = User.new(signup_params)
      flash.now[:alert] = t("errors.too_many_requests")
      render :new, status: :too_many_requests
      return
    end

    @user = User.new(signup_params)
```

(The rest of `#create` is unchanged.)

- [ ] **Step 5: Apply it to password reset**

In `app/controllers/password_resets_controller.rb`:

```ruby
class PasswordResetsController < ApplicationController
  include RequestThrottling
```

and in `#create`, before the lookup:

```ruby
  def create
    # Checked before the lookup, so a throttled response cannot become the
    # address oracle the identical-response design below exists to prevent.
    unless throttle!("reset")
      flash.now[:alert] = t("errors.too_many_requests")
      render :new, status: :too_many_requests
      return
    end

    user = User.find_by(email: params[:email].to_s.strip)
```

- [ ] **Step 6: Add the locale key to all four files**

In `config/locales/ru.yml`, inside the existing `errors:` block:

```yaml
    too_many_requests: "Слишком много попыток. Попробуйте позже."
```

`en.yml`: `too_many_requests: "Too many attempts. Please try again later."`
`uk.yml`: `too_many_requests: "Забагато спроб. Спробуйте пізніше."`
`ka.yml`: `too_many_requests: "ძალიან ბევრი მცდელობა. სცადეთ მოგვიანებით."`

If there is no top-level `errors:` block in a file, add the key under the block that already holds
`must_be_superadmin` — that is the errors namespace this app uses. Do **not** create a second block
with a name that already exists; `spec/i18n_spec.rb` fails the build on duplicate YAML keys.

- [ ] **Step 6b: Stop the limiter leaking across Cucumber scenarios**

This is the step most likely to be skipped and most likely to break the acceptance suite.

`Rails.cache` is process-global. Cucumber runs all 232 scenarios in **one** process, and every request
in the suite comes from `127.0.0.1` — so with a default of 5 signups per 3600 seconds, the counter
does not reset between scenarios and signups start being refused partway through the run. The failure
looks like an unrelated scenario breaking, which is the worst possible signal.

`features/support/env.rb` is a step-definition support file, not a `.feature` file, so it is fair game
(see the acceptance-suite rule in `CLAUDE.md`). Add this next to the existing `Before { I18n.locale = :ru }`
hook at line 38:

```ruby
# Rails.cache is process-global and the whole suite runs in one process from one
# address, so without this the rate-limit counters accumulate ACROSS scenarios:
# the sixth scenario to register a user would be refused, and would fail looking
# like a defect in whatever it was actually testing.
Before { Rails.cache.clear }
```

Note this also means the limiter is genuinely exercised *within* a scenario — which is correct. No
frozen scenario registers more than a handful of users in one run.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/throttling_spec.rb spec/i18n_spec.rb
```

Expected: PASS.

- [ ] **Step 8: Mutation-test the two properties that matter most**

- **The "zero disables" branch:** change `return true if limit.zero?` to `return false if limit.zero?`.
  The "treats a limit of zero as disabled" example must go RED. Restore.
- **Per-IP keying:** remove `#{request.remote_ip}:` from the cache key. The "counts per client
  address" example must go RED. Restore.

Record both outputs. If either stays green, the assertion is not testing what it claims and must be
rewritten before you continue.

- [ ] **Step 9: Full suite, then commit**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
git add app/controllers/concerns/request_throttling.rb app/controllers/users_controller.rb app/controllers/password_resets_controller.rb config/locales features/support/env.rb spec/requests/throttling_spec.rb
git commit -m "Rate-limit the two endpoints that send mail to a chosen address"
```

Expected: baseline **+12** — Task 1's two examples in this file are replaced by six, so this
file's contribution goes from 2 to 6. **Report and STOP if any signup or login example
outside this file changed** — several frozen Cucumber scenarios sign users up, and a limit of 5/hour
could bite a scenario that registers more than five users from one address.

---

## Task 4: The superadmin settings screen

**Files:**
- Create: `app/controllers/admin/settings_controller.rb`
- Create: `app/views/admin/settings/show.html.erb`
- Create: `spec/requests/admin_settings_spec.rb`
- Modify: `config/routes.rb`
- Modify: `app/views/admin/dashboard/show.html.erb`
- Modify: `config/locales/{ru,en,uk,ka}.yml`

**Interfaces:**
- Consumes: `Setting::DEFAULTS`, `Setting.integer`, `Setting.put` from Task 2;
  `record_admin_action(action, target = nil, details = nil)` from
  `app/controllers/concerns/admin_audit.rb`.
- Produces: `GET /admin/settings` (`admin_settings_path`) and `PATCH /admin/settings`.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/admin_settings_spec.rb`:

```ruby
require "rails_helper"

describe "the superadmin settings screen", type: :request do
  let(:superadmin) do
    u = create_user
    u.update!(:is_superadmin => true)
    u
  end
  let(:ordinary) { create_user }

  def login_as(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses an ordinary user" do
    login_as(ordinary)
    get admin_settings_path

    expect(response).not_to have_http_status(:ok)
  end

  it "refuses a signed-out visitor" do
    get admin_settings_path

    expect(response).not_to have_http_status(:ok)
  end

  it "shows the current values to a superadmin" do
    Setting.put("signup_max", 9)
    login_as(superadmin)
    get admin_settings_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("9")
  end

  it "stores a changed limit" do
    login_as(superadmin)

    patch admin_settings_path, :params => { :settings => { "signup_max" => "12" } }

    expect(Setting.integer("signup_max")).to eq(12)
  end

  it "records the change in the audit log" do
    login_as(superadmin)

    expect {
      patch admin_settings_path, :params => { :settings => { "reset_max" => "7" } }
    }.to change { AdminAction.where(:action => "update_settings").count }.by(1)

    entry = AdminAction.where(:action => "update_settings").last
    expect(entry.actor_id).to eq(superadmin.id)
    expect(entry.details).to include("reset_max")
  end

  # A rejected value must not be written, and must not be reported as saved --
  # an operator who believes a limit is 0 when it is still 5 will not understand
  # why the console is still refusing signups.
  it "refuses a negative value without writing it" do
    login_as(superadmin)

    patch admin_settings_path, :params => { :settings => { "signup_max" => "-3" } }

    expect(Setting.integer("signup_max")).to eq(Setting::DEFAULTS.fetch("signup_max"))
    expect(response).to have_http_status(:unprocessable_entity)
  end

  # Anything not in DEFAULTS is ignored rather than saved: without this, a
  # crafted form post writes arbitrary rows into the settings table.
  it "ignores a name that is not a known setting" do
    login_as(superadmin)

    expect {
      patch admin_settings_path, :params => { :settings => { "wat" => "1" } }
    }.not_to change { Setting.count }
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_settings_spec.rb
```

Expected: FAIL with `undefined local variable or method 'admin_settings_path'`.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, inside the existing `namespace :admin do` block, alongside `resources :audit`:

```ruby
    get   "/settings", to: "settings#show",   as: :settings
    patch "/settings", to: "settings#update"
```

- [ ] **Step 4: Write the controller**

Create `app/controllers/admin/settings_controller.rb`:

```ruby
# -*- encoding : utf-8 -*-
class Admin::SettingsController < ApplicationController
  before_action :require_authentication!
  before_action :require_superadmin!

  def show
    @values = current_values
  end

  # Every key is validated against Setting::DEFAULTS before anything is written,
  # and the whole submission is applied in one transaction: a form that half
  # saved would leave the operator with no way to tell which half.
  def update
    submitted = params.fetch(:settings, {}).to_unsafe_h.slice(*Setting::DEFAULTS.keys)

    begin
      Setting.transaction do
        submitted.each { |name, value| Setting.put(name, Integer(value, 10)) }
      end
    rescue ActiveRecord::RecordInvalid, ArgumentError, TypeError
      @values = current_values
      flash.now[:alert] = t("admin.settings.invalid")
      render :show, status: :unprocessable_entity
      return
    end

    # Details, not just the action: "someone changed the limits" is not an
    # audit trail. The values are the whole content of the change.
    record_admin_action("update_settings", nil,
                        submitted.map { |k, v| "#{k}=#{v}" }.join(", "))
    redirect_to admin_settings_path, :notice => t("admin.settings.saved")
  end

  private

  def current_values
    Setting::DEFAULTS.keys.index_with { |name| Setting.integer(name) }
  end
end
```

- [ ] **Step 5: Write the view**

Create `app/views/admin/settings/show.html.erb`:

```erb
<h1><%= t("admin.settings.title") %></h1>

<p class="hint-text"><%= t("admin.settings.explanation") %></p>

<%= form_with url: admin_settings_path, method: :patch do %>
  <% @values.each do |name, value| %>
    <div class="field">
      <%= label_tag "settings_#{name}", t("admin.settings.names.#{name}") %>
      <%= number_field_tag "settings[#{name}]", value, :id => "settings_#{name}", :min => 0 %>
    </div>
  <% end %>

  <%= submit_tag t("admin.settings.submit"), class: "btn btn--go" %>
<% end %>
```

- [ ] **Step 6: Link it from the admin dashboard**

At the end of `app/views/admin/dashboard/show.html.erb`:

```erb
<p><%= link_to t("admin.settings.title"), admin_settings_path %></p>
```

- [ ] **Step 7: Add the locale keys to all four files**

In `config/locales/ru.yml`, inside the existing `admin:` block (as a sibling of `dashboard:`,
`users:`, `audit:`):

```yaml
    settings:
      title: "Настройки ограничений"
      explanation: "Ограничения действуют на один IP-адрес за указанный период. 0 отключает ограничение."
      submit: "Сохранить"
      saved: "Настройки сохранены"
      invalid: "Значение должно быть целым числом не меньше нуля"
      names:
        signup_max: "Регистраций с одного адреса"
        signup_window_seconds: "Период для регистраций (секунд)"
        reset_max: "Запросов сброса пароля с одного адреса"
        reset_window_seconds: "Период для сброса пароля (секунд)"
```

`en.yml` (same structure):

```yaml
    settings:
      title: "Rate limits"
      explanation: "Limits apply per IP address per window. 0 disables the limit."
      submit: "Save"
      saved: "Settings saved"
      invalid: "Value must be a whole number of zero or more"
      names:
        signup_max: "Signups per address"
        signup_window_seconds: "Signup window (seconds)"
        reset_max: "Password reset requests per address"
        reset_window_seconds: "Password reset window (seconds)"
```

Add the same structure to `uk.yml` and `ka.yml`, translated. `spec/i18n_spec.rb` requires exact
`ru`↔`en` parity and `uk`/`ka` to be a subset, so those two may lag in wording quality but must not
introduce keys the others lack.

- [ ] **Step 8: Run the tests to verify they pass**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_settings_spec.rb spec/i18n_spec.rb
```

Expected: PASS, 7 examples plus i18n.

- [ ] **Step 9: Mutation-test the authorisation and the whitelist**

- Comment out `before_action :require_superadmin!`. The "refuses an ordinary user" example must go
  RED. Restore. (This is the assertion most likely to be vacuous — `not_to have_http_status(:ok)`
  passes for a redirect *and* for a 500, so confirm it fails for the right reason: a 200.)
- Remove `.slice(*Setting::DEFAULTS.keys)`. The "ignores a name that is not a known setting" example
  must go RED. Restore.

- [ ] **Step 10: Full suite, then commit**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
git add app/controllers/admin/settings_controller.rb app/views/admin/settings app/views/admin/dashboard/show.html.erb config/routes.rb config/locales spec/requests/admin_settings_spec.rb
git commit -m "Let a superadmin change the rate limits without a deploy"
```

Expected: baseline **+19**.

---

## Task 5: The signup honeypot, with no UI impact

**Files:**
- Modify: `app/views/users/new.html.erb`
- Modify: `app/controllers/users_controller.rb` (`#create`)
- Modify: `public/stylesheets/components.css`
- Create: `spec/requests/signup_honeypot_spec.rb`

**Interfaces:**
- Consumes: `throttle!("signup")` from Task 3 — the honeypot check runs **before** it, so a bot's
  submission does not consume a real client's budget in the shared window.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/signup_honeypot_spec.rb`:

```ruby
require "rails_helper"

describe "the signup honeypot", type: :request do
  it "creates no user and sends no mail when the trap field is filled" do
    expect {
      expect {
        post users_path, :params => { :user => { :nickname => "bot", :email => "bot@example.com" },
                                      :website => "http://spam.example" }
      }.not_to change { User.count }
    }.not_to change { ActionMailer::Base.deliveries.size }
  end

  # The response must not tell the operator of a bot which field gave them away,
  # or the trap is worth nothing after the first attempt.
  it "answers a trapped submission with an ordinary redirect" do
    post users_path, :params => { :user => { :nickname => "bot", :email => "bot@example.com" },
                                  :website => "http://spam.example" }

    expect(response).to have_http_status(:found)
    expect(response.body).not_to include("website")
  end

  it "still registers a normal submission with the field left empty" do
    expect {
      post users_path, :params => { :user => { :nickname => "human", :email => "human@example.com" },
                                    :website => "" }
    }.to change { User.count }.by(1)
  end

  # An absent parameter is the normal case for anything that is not a browser
  # rendering the form -- the Cucumber suite included.
  it "still registers when the field is absent entirely" do
    expect {
      post users_path, :params => { :user => { :nickname => "curl", :email => "curl@example.com" } }
    }.to change { User.count }.by(1)
  end

  it "renders the trap field on the form" do
    get signup_path

    expect(response.body).to include('name="website"')
    expect(response.body).to include('aria-hidden="true"')
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/signup_honeypot_spec.rb
```

Expected: FAIL — the first two examples create a user, and the last finds no `name="website"`.

- [ ] **Step 3: Add the field to the form**

In `app/views/users/new.html.erb`, between the email field and the submit button:

```erb
  <%# Honeypot. Hidden from people, offered to robots: a scripted client fills
      every input it parses, a human never sees this one. Deliberately NOT
      type="hidden" -- plenty of bots skip those, and the point is that it looks
      like an ordinary field to anything reading the markup.

      The name is bait ("website" is a field spam tooling expects on a signup
      form), so it must not be renamed to anything self-describing.

      Three attributes matter for people, not robots:
        aria-hidden  keeps it out of the screen-reader tree -- without it this
                     traps blind users and nobody else
        tabindex=-1  keeps it out of the keyboard order
        autocomplete keeps password managers from filling it helpfully

      Hidden by class, not by an inline style, so the rule lives with the rest
      of the CSS -- see .hp-field in components.css. %>
  <div class="hp-field" aria-hidden="true">
    <%= label_tag :website, "Website" %>
    <%= text_field_tag :website, nil, :tabindex => -1, :autocomplete => "off" %>
  </div>
```

- [ ] **Step 4: Add the hiding rule**

At the end of `public/stylesheets/components.css`:

```css
/* The signup honeypot (app/views/users/new.html.erb). Positioned off-screen
   rather than display:none or visibility:hidden -- some scripted clients skip
   fields whose computed style hides them, and the field is only useful if a
   robot believes it is real.

   Absolutely positioned so it is out of flow and can shift nothing: the form
   below it is laid out exactly as if this element did not exist, on any
   viewport. left, not top, so it never lengthens the page and never creates a
   horizontal scrollbar (overflow to the LEFT of the viewport does not extend
   the scrollable area; overflow to the right would). */
.hp-field {
  position: absolute;
  left: -9999px;
  width: 1px;
  height: 1px;
  overflow: hidden;
}
```

- [ ] **Step 5: Reject trapped submissions**

In `app/controllers/users_controller.rb`, at the very top of `#create` — **before** the throttle,
so a bot's flood does not consume the shared per-IP budget that real people share:

```ruby
  def create
    # Honeypot: see the field's comment in app/views/users/new.html.erb. Read
    # straight off params -- signup_params permits only nickname and email, so
    # this would be stripped before it could be checked.
    #
    # Answers with the same redirect an ordinary refusal gets rather than an
    # error, so an operator watching responses cannot find the trap by diffing
    # them. Nothing is created and nothing is mailed.
    if params[:website].present?
      redirect_to login_path, :notice => t("users.create.check_your_mail")
      return
    end

    unless throttle!("signup")
```

- [ ] **Step 6: Add the locale key to all four files**

`ru.yml`, inside the existing `users:` block. Verified: that block currently holds `new:`, `edit:` and
`index:` and has **no** `create:` sub-block, so add one as a sibling of `new:`:

```yaml
    create:
      check_your_mail: "Проверьте почту"
```

`en.yml`: `check_your_mail: "Check your e-mail"`
`uk.yml`: `check_your_mail: "Перевірте пошту"`
`ka.yml`: `check_your_mail: "შეამოწმეთ ფოსტა"`

- [ ] **Step 7: Run the tests to verify they pass**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/signup_honeypot_spec.rb spec/i18n_spec.rb
```

Expected: PASS, 5 examples plus i18n.

- [ ] **Step 8: Prove the field changes nothing on screen**

This is the explicit requirement — no UI impact on desktop **or** mobile — and it cannot be checked
from RSpec. Use the browser harness (the same one used for the playbar work; the procedure is
recorded in `public/stylesheets/screens.css`'s `.playbar` comment and in the notes below).

Write a throwaway spec that renders the signup page to a file:

```ruby
require "rails_helper"

describe "signup page dump", type: :request do
  it "dumps" do
    get signup_path
    File.write(ENV.fetch("OUT"), response.body)
  end
end
```

Then, with the CSS change **stashed** and again with it applied, serve `public/` and measure:

```bash
cd public && python3 -m http.server 8731 --bind 127.0.0.1 &
SH=~/.cache/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-linux64/chrome-headless-shell
"$SH" --no-sandbox --disable-gpu --hide-scrollbars --window-size=390,660 \
  --virtual-time-budget=4000 --dump-dom "http://127.0.0.1:8731/signup_probe.html"
```

with a probe script that reports:

```javascript
var de = document.documentElement, hp = document.querySelector('.hp-field');
var form = document.querySelector('form');
JSON.stringify({
  horizontalOverflow: de.scrollWidth - de.clientWidth,   // must be 0
  documentHeight:     de.scrollHeight,                   // must equal the no-honeypot run
  formHeight:         Math.round(form.getBoundingClientRect().height),
  honeypotOffscreen:  hp.getBoundingClientRect().right < 0,
  honeypotAriaHidden: hp.getAttribute('aria-hidden')
});
```

**Pass conditions, at 390x660 (phone) and 1280x800 (desktop):**
- `horizontalOverflow` is `0` in both runs,
- `documentHeight` and `formHeight` are **identical** with and without the honeypot,
- `honeypotOffscreen` is `true`,
- `honeypotAriaHidden` is `"true"`.

Record the six numbers in your report. If `documentHeight` differs by even a pixel, the field is
affecting layout and the CSS is wrong — do not proceed.

Delete the throwaway spec and the staged HTML afterwards.

- [ ] **Step 9: Mutation-test the trap**

Change `if params[:website].present?` to `if params[:website].blank?`. The two "creates no user"
examples and the two "still registers" examples must all flip. Restore, confirm green.

- [ ] **Step 10: Commit**

```bash
git add app/views/users/new.html.erb app/controllers/users_controller.rb public/stylesheets/components.css config/locales spec/requests/signup_honeypot_spec.rb
git commit -m "Add a signup honeypot that costs people nothing"
```

Expected full suite: baseline **+24**.

---

## Task 6: Reset issues a generated password, after a confirmation

## DROPPED — owner's decision, 2026-08-09

Not implemented. The owner chose to keep the existing choose-your-own-password form, on the finding
recorded in "Decision to confirm" above: the anti-lockout property this task was meant to buy already
holds, because `PasswordResetsController#create` only issues a token and mails a link. The task text
is kept below unchanged, so the reasoning survives if it is ever revisited — see item 24 of
`docs/security/2026-08-08-follow-up-queue.md`.

**Read the "Decision to confirm" section at the top of this plan before starting.** This task changes
a security-relevant flow and its trade-off has been recorded rather than assumed. If the owner has not
confirmed, ask before implementing.

**Files:**
- Modify: `app/controllers/password_resets_controller.rb` (`#edit`, `#update`)
- Modify: `app/views/password_resets/edit.html.erb`
- Modify: `app/mailers/notification_mailer.rb`
- Create: `app/views/notification_mailer/password_issued.text.erb`
- Modify: `config/routes.rb`
- Modify: `config/locales/{ru,en,uk,ka}.yml`
- Modify: `spec/requests/password_reset_spec.rb`

**Interfaces:**
- Consumes: `User#issue_reset_password_token!`, `User.find_by_reset_token(raw)`,
  `User#clear_reset_password_token!`, `User::RESET_PASSWORD_VALID_FOR` — all already in
  `app/models/user.rb`.
- Produces: `NotificationMailer.password_issued(user, password)`.

- [ ] **Step 1: Write the failing tests**

Replace `spec/requests/password_reset_spec.rb`'s flow examples with these, keeping the existing
"does not reveal whether an address is registered", "refuses an expired token" and "refuses a token
twice" examples (adjusting them to the new verb where they post):

```ruby
  it "does not change the password merely by following the link" do
    user = create_user
    token = user.issue_reset_password_token!
    before = user.reload.crypted_password

    get edit_password_reset_path(:token => token)

    expect(response).to have_http_status(:ok)
    expect(user.reload.crypted_password).to eq(before)
  end

  it "issues a new password and mails it when the confirmation is submitted" do
    user = create_user
    token = user.issue_reset_password_token!
    before = user.reload.crypted_password

    expect {
      patch password_reset_path, :params => { :token => token }
    }.to change { ActionMailer::Base.deliveries.size }.by(1)

    expect(user.reload.crypted_password).not_to eq(before)

    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq([ user.email ])
  end

  it "mails a password that actually works" do
    user = create_user
    token = user.issue_reset_password_token!

    patch password_reset_path, :params => { :token => token }

    issued = ActionMailer::Base.deliveries.last.body.to_s[/[A-Za-z0-9]{12}/]
    expect(issued).to be_present
    expect(user.reload.authenticate(issued)).to be_truthy
  end

  it "spends the token, so the link cannot issue a second password" do
    user = create_user
    token = user.issue_reset_password_token!
    patch password_reset_path, :params => { :token => token }

    expect {
      patch password_reset_path, :params => { :token => token }
    }.not_to change { ActionMailer::Base.deliveries.size }
  end
```

- [ ] **Step 2: Run them and watch them fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/password_reset_spec.rb
```

Expected: FAIL — `#update` currently requires `params[:user][:password]` and renders the form again
when it is missing, so no mail is sent and the password does not change.

- [ ] **Step 3: Turn the landing page into a confirmation**

Replace the contents of `app/views/password_resets/edit.html.erb` with:

```erb
<h1><%= t("password_resets.edit.title") %></h1>

<p><%= t("password_resets.edit.explanation") %></p>

<%# A button, not a link, and PATCH rather than GET. The URL in the e-mail is
    followed automatically by mail scanners and link-prefetching clients, so a
    GET that issued the password would reset accounts nobody asked to reset --
    the deliverability equivalent of a mutating GET. The click below is a
    person. %>
<%= form_with url: password_reset_path, method: :patch do %>
  <%= hidden_field_tag :token, @token %>
  <%= submit_tag t("password_resets.edit.submit"), class: "btn btn--go" %>
<% end %>
```

- [ ] **Step 4: Rewrite `#update` to issue and mail**

In `app/controllers/password_resets_controller.rb`:

```ruby
  # The confirmation from #edit. Generates the new password, mails it, and
  # spends the token. The user never chooses a password here -- signup does not
  # either, and the profile form is where a chosen one is set (which requires
  # the current password, so the mailed one is the proof of ownership).
  def update
    @token = params[:token].to_s
    user = User.find_by_reset_token(@token)

    unless user
      redirect_to new_password_reset_path, alert: t("password_resets.invalid")
      return
    end

    # Same generator and length as signup (users_controller.rb).
    issued = SecureRandom.alphanumeric(12)
    user.password = issued
    user.password_confirmation = issued
    user.save!

    # Spent before the mail goes out: a delivery failure must not leave a live
    # token behind, and the user can always ask for another link.
    user.clear_reset_password_token!

    NotificationMailer.password_issued(user, issued).deliver_now

    # The password change has already rotated session_token, so every other
    # session is dead; this drops the current one too.
    reset_session
    redirect_to login_path, notice: t("password_resets.update.done")
  end
```

- [ ] **Step 5: Add the mailer method**

In `app/mailers/notification_mailer.rb`, after `#password_reset`:

```ruby
  # The SECOND reset mail: the first carried a link, this one carries the
  # password that link produced.
  def password_issued(user, password)
    @user = user
    @password = password
    @host = app_host
    mail_in_recipient_locale(user, :password_issued)
  end
```

- [ ] **Step 6: Add the mail body**

Create `app/views/notification_mailer/password_issued.text.erb`:

```erb
<%= t("notification_mailer.password_issued.body",
      nickname: @user.nickname,
      password: @password,
      host: @host) %>
```

- [ ] **Step 7: Add the locale keys to all four files**

`ru.yml` — under `notification_mailer:`:

```yaml
    password_issued:
      subject: "Новый пароль"
      body: |
        %{nickname}, здравствуйте!

        Ваш новый пароль: %{password}

        Войдите с ним на %{host} и сразу смените его в личном кабинете.
```

`password_resets.edit` **already exists** and currently reads:

```yaml
    edit:
      title: "Новый пароль"
      password: "Новый пароль"
      password_confirmation: "Подтверждение пароля"
      submit: "Сохранить пароль"
```

Do not add a second `edit:` block — `spec/i18n_spec.rb` fails the build on duplicate YAML keys.
Edit this one in place: change the two values, add `explanation`, and **delete `password` and
`password_confirmation`**, which the confirmation page no longer renders. Deleting them from `ru.yml`
alone breaks the exact `ru`↔`en` parity check, so they must go from all four files together.

```yaml
    edit:
      title: "Сброс пароля"
      explanation: "Нажмите кнопку — мы пришлём новый пароль вторым письмом."
      submit: "Прислать новый пароль"
```

Mirror both blocks into `en.yml`, `uk.yml` and `ka.yml`. The mailer subject key must exist in every
locale or `mail_in_recipient_locale` will render `translation missing:` into a real subject line.

- [ ] **Step 8: Run the tests to verify they pass**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/password_reset_spec.rb spec/i18n_spec.rb
```

Expected: PASS.

- [ ] **Step 9: Mutation-test the two properties this task exists for**

- **The link must not mutate.** Move the password generation from `#update` into `#edit`. The "does
  not change the password merely by following the link" example must go RED. Restore.
- **The token must be single-use.** Delete `user.clear_reset_password_token!`. The "spends the token"
  example must go RED. Restore.

- [ ] **Step 10: Commit**

```bash
git add app/controllers/password_resets_controller.rb app/views/password_resets/edit.html.erb app/mailers/notification_mailer.rb app/views/notification_mailer/password_issued.text.erb config/locales spec/requests/password_reset_spec.rb
git commit -m "Issue the reset password on confirmation, in a second e-mail"
```

---

## Task 7: Record what shipped

**Files:**
- Modify: `docs/security/2026-08-08-follow-up-queue.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the follow-up queue**

Mark the newly-covered ground and add what this plan deliberately did **not** do:

- Note against item #10 ("The welcome letter carries the password in cleartext") that Task 6 **added a
  second** cleartext-password mail rather than removing the first — an explicit owner decision, so
  the item's scope grew rather than shrank.
- Add a new item: **mail is still delivered synchronously** (`deliver_now`) on both endpoints, so a
  throttled-but-permitted request still holds a Puma thread for an SMTP round trip. Moving to
  `deliver_later` needs a durable queue: Rails' default `:async` adapter drops jobs on deploy, which
  would silently lose a welcome letter or an issued password.
- Add a new item: **nothing alerts on throttle trips.** The `[throttle]` log line exists but nobody
  reads it; the first sign of an attack would be Gmail suspending the sending account. Same blind spot
  as the backup timer.

- [ ] **Step 2: Update CLAUDE.md**

Add a short paragraph to the deployment/testing notes recording that the app now has a configured
cache store, that it is `:memory_store` and why, and the single-process assumption that makes it
valid.

- [ ] **Step 3: Run both suites one final time**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
```

The controller (not an implementer) then runs:

```bash
bundle exec cucumber
```

Expected: RSpec 0 failures, 6 pending. Cucumber **232 scenarios (2 undefined, 230 passed) / 2342
steps** — exactly baseline. Any deviation is a real regression: signup is exercised by frozen
scenarios, and a 5-per-hour limit is the most likely thing to bite them.

- [ ] **Step 4: Commit**

```bash
git add docs/security/2026-08-08-follow-up-queue.md CLAUDE.md
git commit -m "Record what the abuse hardening covered, and what it did not"
```

---

## After the PR is deployed

Run the `remote_ip` verification from **Task 1, Step 9**. Until it passes, treat the limiter as
unproven: if forwarded headers are not being honoured it is keying every request in the world to one
counter, and the first five signups of each hour would lock out everyone else. This is the one part of
this plan that no test in the repository can cover.
