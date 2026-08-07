# Profile Contacts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dead `icq_number` and `jabber_id` profile fields with Instagram, Telegram and five messenger-availability flags.

**Architecture:** Additive first, subtractive last. Task 1 adds columns and normalisation; Task 2 renders the new fields alongside the old ones; Task 3 removes ICQ/Jabber everywhere at once — schema, views, params, locales, specs, and the one authorised feature amendment. This ordering is deliberate: dropping the columns before the views stop reading them raises `NoMethodError` on the profile page, so a "migration first" plan would leave the suite red for two tasks. Every task here ends green.

**Tech Stack:** Rails 8.0.5.1, Ruby 3.3.12, sqlite (dev/test), RSpec, Cucumber (Russian Gherkin).

## Global Constraints

- Ruby is not on `PATH` in non-login shells. Prefix every command: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- Branch: `design/profiles-and-games-list`, already cut from master at `4e568b1`.
- Baseline that must hold: **762 rspec examples / 0 failures / 6 pending**, and **234 cucumber
  scenarios (2 pre-existing "undefined") / 2362 steps** — MEASURED on master at `634d30e`. The
  figure originally written here (711) predates PRs #17-#22. Re-measure rather than trusting any
  printed total, and report actuals.
- **`:timezone` is now in `profile_params` and there is a timezone field on the profile form**,
  both added by PR #22 after this plan was written. Do not drop either. `spec/requests/
  timezone_preference_spec.rb` covers them.
- `features/**/*.feature` is read-only **except** `features/games/user-profile-view-and-edit.feature` in Task 3, authorised by the repository owner on 2026-08-06. No other feature file may be touched for any reason.
- Every user-facing string is a `t()` key present in **all four** of `config/locales/{ru,en,uk,ka}.yml`. Use the exact translations given in this plan — do not invent your own, and do not copy Russian into `uk`/`ka`.
- Hash rockets (`:key => value`) for symbol keys; match the surrounding file.
- Run `bin/rails db:test:prepare` after any migration.

---

### Task 1: Add the new contact columns and handle normalisation

**Files:**
- Create: `db/migrate/<timestamp>_add_contact_fields_to_users.rb`
- Modify: `app/models/user.rb`
- Test: `spec/models/user/contact_normalisation_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `User#instagram`, `User#telegram_id` (both normalised to a bare handle or `nil`); `User#on_telegram`, `#on_whatsapp`, `#on_viber`, `#on_signal`, `#on_max` (booleans, default `false`, `null: false`).

- [ ] **Step 1: Write the failing spec**

Create `spec/models/user/contact_normalisation_spec.rb`:

```ruby
require "rails_helper"

describe User, "contact handle normalisation" do
  let(:user) { create_user }

  # Stored as a bare handle so the profile can render a working link and two
  # players who typed the same handle differently are stored identically.
  describe "#instagram" do
    {
      "@player"                      => "player",
      "https://instagram.com/player" => "player",
      "http://instagram.com/player"  => "player",
      "www.instagram.com/player/"    => "player",
      "instagram.com/player"         => "player",
      "  player  "                   => "player"
    }.each do |typed, stored|
      it "stores #{typed.inspect} as #{stored.inspect}" do
        user.update!(:instagram => typed)
        expect(user.reload.instagram).to eq(stored)
      end
    end

    it "stores an empty value as nil, so a cleared field is absent rather than blank" do
      user.update!(:instagram => "player")
      user.update!(:instagram => "")

      expect(user.reload.instagram).to be_nil
    end
  end

  describe "#telegram_id" do
    {
      "@player"              => "player",
      "https://t.me/player"  => "player",
      "t.me/player"          => "player",
      "telegram.me/player/"  => "player",
      "  player  "           => "player"
    }.each do |typed, stored|
      it "stores #{typed.inspect} as #{stored.inspect}" do
        user.update!(:telegram_id => typed)
        expect(user.reload.telegram_id).to eq(stored)
      end
    end
  end

  # No format validation beyond normalisation: Instagram's and Telegram's own
  # handle rules change, and rejecting a valid handle is worse here than
  # storing an odd one. This is a contact note for a human, not an API key.
  it "accepts a handle it does not recognise rather than rejecting it" do
    user.update!(:instagram => "some.unusual_handle-99")

    expect(user.reload.instagram).to eq("some.unusual_handle-99")
  end

  describe "messenger availability" do
    it "defaults every flag to false" do
      expect(user.on_telegram).to be false
      expect(user.on_whatsapp).to be false
      expect(user.on_viber).to be false
      expect(user.on_signal).to be false
      expect(user.on_max).to be false
    end

    # Independent by design: a player may record a handle without ticking the
    # box ("that is my handle, but reach me on Signal"). Nothing derives one
    # from the other.
    it "does not tie the telegram flag to the telegram handle" do
      user.update!(:telegram_id => "player")

      expect(user.reload.on_telegram).to be false
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/user/contact_normalisation_spec.rb
```

Expected: every example errors with `NoMethodError: undefined method 'instagram='`.

- [ ] **Step 3: Write the migration**

```bash
bin/rails generate migration AddContactFieldsToUsers
```

Replace the generated body with:

```ruby
class AddContactFieldsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :instagram,   :string
    add_column :users, :telegram_id, :string

    add_column :users, :on_telegram, :boolean, :default => false, :null => false
    add_column :users, :on_whatsapp, :boolean, :default => false, :null => false
    add_column :users, :on_viber,    :boolean, :default => false, :null => false
    add_column :users, :on_signal,   :boolean, :default => false, :null => false
    add_column :users, :on_max,      :boolean, :default => false, :null => false
  end
end
```

- [ ] **Step 4: Run the migration against both databases**

```bash
bin/rails db:migrate
bin/rails db:test:prepare
```

Confirm `db/schema.rb` now lists all seven columns on `users`.

- [ ] **Step 5: Add the normalisation callback**

In `app/models/user.rb`, add near the other constants and callbacks:

```ruby
  # Handles are stored bare -- no leading "@", no host, no scheme -- so the
  # profile can render a working link, and two players who typed the same
  # handle differently are stored identically. Each key is a column; each
  # value is the hosts to strip for that column.
  CONTACT_HANDLE_HOSTS = {
    :instagram   => %w[instagram.com],
    :telegram_id => %w[t.me telegram.me]
  }.freeze

  before_validation :normalise_contact_handles
```

and, under `private` (or `protected`, matching whatever the file already uses):

```ruby
  # Order matters: scheme, then "www.", then the host, then a leading "@",
  # then a trailing slash. Stripping "@" first would leave "@" embedded in a
  # pasted URL untouched.
  def normalise_contact_handles
    CONTACT_HANDLE_HOSTS.each do |field, hosts|
      value = self[field].to_s.strip

      value = value.sub(%r{\Ahttps?://}i, "")
      value = value.sub(%r{\Awww\.}i, "")
      hosts.each { |host| value = value.sub(%r{\A#{Regexp.escape(host)}/}i, "") }
      value = value.sub(/\A@/, "")
      value = value.sub(%r{/\z}, "")

      # presence, not the raw value: an emptied field must land as NULL so the
      # views can test presence to decide whether to render a row at all.
      self[field] = value.presence
    end
  end
```

- [ ] **Step 6: Run the spec and the full suite**

```bash
bundle exec rspec spec/models/user/contact_normalisation_spec.rb
bundle exec rspec
```

Expected: the new file passes; the full suite is **762 + 16 = 778 examples, 0 failures, 6 pending**. Report actuals.

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/models/user.rb spec/models/user/contact_normalisation_spec.rb
git commit -m "Add Instagram, Telegram and messenger-availability fields to users

Handles are normalised to a bare handle on save -- scheme, www., host,
leading @ and trailing slash all stripped -- so the profile can render a
working link and two players who typed the same handle differently are
stored identically. An emptied field lands as NULL rather than \"\", because
the views test presence to decide whether to render a row.

Purely additive: ICQ and Jabber are untouched and the suite stays green.
They come out in a later commit, once nothing reads them."
```

---

### Task 2: Render the new fields on all three profile screens

**Files:**
- Modify: `app/controllers/users_controller.rb` (`profile_params`, ~line 81, and the comment at ~line 73)
- Modify: `app/views/users/edit.html.erb`
- Modify: `app/views/users/index.html.erb`
- Modify: `app/views/admin/users/show.html.erb`
- Modify: `config/locales/ru.yml`, `en.yml`, `uk.yml`, `ka.yml`
- Modify: `spec/i18n_spec.rb` (the `known_legitimate_duplicates` list, ~line 95)
- Test: `spec/views/users_spec.rb`, `spec/requests/admin_reporting_spec.rb`

**Interfaces:**
- Consumes: `User#instagram`, `#telegram_id`, `#on_telegram`, `#on_whatsapp`, `#on_viber`, `#on_signal`, `#on_max` from Task 1.
- Produces: locale keys `messengers.{telegram,whatsapp,viber,signal,max}`, `users.edit.{instagram_label,telegram_label,messengers_label}`, `users.index.{instagram_label,telegram_label,messengers_label}`, `admin.users.show.{instagram,telegram,messengers}`.

ICQ and Jabber stay on all three screens through this task. They come out in Task 3.

- [ ] **Step 1: Add the locale keys, all four files**

Add a **new top-level** `messengers:` section to each locale file. The five brand names are identical in every language by design — that is why they live in one shared namespace rather than being repeated per view.

`config/locales/ru.yml`, `en.yml`, `uk.yml`, `ka.yml` — identical block in all four:

```yaml
  messengers:
    telegram: "Telegram"
    whatsapp: "WhatsApp"
    viber: "Viber"
    signal: "Signal"
    max: "MAX"
```

Then, under `users.edit` in each file:

| key | ru | en | uk | ka |
|---|---|---|---|---|
| `instagram_label` | `Instagram` | `Instagram` | `Instagram` | `Instagram` |
| `telegram_label` | `Telegram` | `Telegram` | `Telegram` | `Telegram` |
| `messengers_label` | `Доступен в мессенджерах` | `Available on` | `Доступний у месенджерах` | `ხელმისაწვდომია მესენჯერებში` |

Under `users.index` in each file (trailing colon, matching the existing labels there):

| key | ru | en | uk | ka |
|---|---|---|---|---|
| `instagram_label` | `Instagram:` | `Instagram:` | `Instagram:` | `Instagram:` |
| `telegram_label` | `Telegram:` | `Telegram:` | `Telegram:` | `Telegram:` |
| `messengers_label` | `Мессенджеры:` | `Messengers:` | `Месенджери:` | `მესენჯერები:` |

Under `admin.users.show` in each file:

| key | ru | en | uk | ka |
|---|---|---|---|---|
| `instagram` | `Instagram` | `Instagram` | `Instagram` | `Instagram` |
| `telegram` | `Telegram` | `Telegram` | `Telegram` | `Telegram` |
| `messengers` | `Мессенджеры` | `Messengers` | `Месенджери` | `მესენჯერები` |

- [ ] **Step 2: Extend the i18n duplicate allowlist**

`spec/i18n_spec.rb:94` fails when an English value is byte-identical to its Russian one, to catch keys nobody translated. Brand names are identical in every locale **by design**, so they must be allowlisted — exactly as `admin.users.show.icq` already is.

In the `known_legitimate_duplicates` array (~line 95), add:

```ruby
      messengers.telegram
      messengers.whatsapp
      messengers.viber
      messengers.signal
      messengers.max
      users.edit.instagram_label
      users.edit.telegram_label
      users.index.instagram_label
      users.index.telegram_label
      admin.users.show.instagram
      admin.users.show.telegram
```

Do **not** remove the four existing ICQ/Jabber entries yet — those keys still exist until Task 3.

- [ ] **Step 3: Run the i18n spec**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/i18n_spec.rb
```

Expected: PASS. If it fails on missing keys, a locale file is missing part of Step 1 — fix that rather than relaxing the spec.

- [ ] **Step 4: Permit the new params**

In `app/controllers/users_controller.rb`, replace `profile_params` (~line 81):

```ruby
  def profile_params
    params.fetch(:user, ActionController::Parameters.new)
          .permit(:nickname, :date_of_birth, :icq_number, :jabber_id,
                   :instagram, :telegram_id,
                   :on_telegram, :on_whatsapp, :on_viber, :on_signal, :on_max,
                   :phone_number, :locale, :timezone, :password, :password_confirmation)
  end
```

Update the comment above it (~line 73) that enumerates the permitted list, adding the seven new attributes.

- [ ] **Step 5: Add the fields to the edit form**

In `app/views/users/edit.html.erb`, after the existing `jabber_id` field block and **before** the captain-only `phone_number` block.

Position matters: `phone_number` is wrapped in `<% if @user.captain? %>`. The new fields are ordinary contact details for **any** player — exactly what `icq_number` and `jabber_id` were — so they must sit outside that conditional. Do not extend the captain condition over them.

```erb
  <div class="field">
    <%= f.label :instagram, t("users.edit.instagram_label") %>
    <%= f.text_field :instagram, autocapitalize: "off", autocorrect: "off", spellcheck: "false" %>
  </div>
  <div class="field">
    <%= f.label :telegram_id, t("users.edit.telegram_label") %>
    <%= f.text_field :telegram_id, autocapitalize: "off", autocorrect: "off", spellcheck: "false" %>
  </div>
  <%# One fieldset rather than five separate .field rows: these are one
      question ("where can we reach you?"), and five stacked label/input
      pairs would read as five unrelated settings. %>
  <fieldset class="field">
    <legend><%= t("users.edit.messengers_label") %></legend>
    <label><%= f.check_box :on_telegram %> <%= t("messengers.telegram") %></label>
    <label><%= f.check_box :on_whatsapp %> <%= t("messengers.whatsapp") %></label>
    <label><%= f.check_box :on_viber %> <%= t("messengers.viber") %></label>
    <label><%= f.check_box :on_signal %> <%= t("messengers.signal") %></label>
    <label><%= f.check_box :on_max %> <%= t("messengers.max") %></label>
  </fieldset>
```

- [ ] **Step 6: Add a shared helper for the messenger list**

Three views render the same list of ticked messengers. Add to `app/helpers/application_helper.rb`, inside `module ApplicationHelper`:

```ruby
  # The messengers a user has ticked, as one comma-joined string, or nil when
  # none are. Three views render this; a row per messenger would triple the
  # height of a two-column table to show five booleans.
  #
  # Ordered by the flag order on the form, not alphabetically, so the reading
  # order matches the order the user ticked them in.
  MESSENGER_FLAGS = %w[telegram whatsapp viber signal max].freeze

  def messenger_list_for(user)
    ticked = MESSENGER_FLAGS.select { |name| user.public_send("on_#{name}") }
    return nil if ticked.empty?

    ticked.map { |name| t("messengers.#{name}") }.join(", ")
  end
```

- [ ] **Step 7: Add the rows to the profile view**

In `app/views/users/index.html.erb`, after the `jabber_label` row and before the captain-only phone row:

```erb
  <% if current_user.instagram.present? %>
    <tr><th><%= t("users.index.instagram_label") %></th>
        <td><%= link_to current_user.instagram, "https://instagram.com/#{current_user.instagram}" %></td></tr>
  <% end %>
  <% if current_user.telegram_id.present? %>
    <tr><th><%= t("users.index.telegram_label") %></th>
        <td><%= link_to current_user.telegram_id, "https://t.me/#{current_user.telegram_id}" %></td></tr>
  <% end %>
  <% if messenger_list_for(current_user) %>
    <tr><th><%= t("users.index.messengers_label") %></th>
        <td><%= messenger_list_for(current_user) %></td></tr>
  <% end %>
```

Rows render only when populated, so a player who fills in neither handle sees no empty rows.

- [ ] **Step 8: Add the rows to the admin user page**

In `app/views/admin/users/show.html.erb`, after the existing `icq` row:

```erb
  <tr><th><%= t("admin.users.show.instagram") %></th><td><%= @user.instagram %></td></tr>
  <tr><th><%= t("admin.users.show.telegram") %></th><td><%= @user.telegram_id %></td></tr>
  <tr><th><%= t("admin.users.show.messengers") %></th><td><%= messenger_list_for(@user) %></td></tr>
```

Unlike the player's own profile these render unconditionally — this is a fixed-shape reference table for an operator, where a blank cell is information ("we have no Telegram for them") rather than clutter.

- [ ] **Step 9: Extend the view specs**

In `spec/views/users_spec.rb`, in the `"users/edit"` example that lists the labels, add after the `jabber_label` line:

```ruby
    expect(rendered).to include(I18n.t("users.edit.instagram_label"))
    expect(rendered).to include(I18n.t("users.edit.telegram_label"))
    expect(rendered).to include(I18n.t("users.edit.messengers_label"))
    expect(rendered).to include(I18n.t("messengers.signal"))
```

Then add a new example to the `"users/index"` describe block:

```ruby
  it "renders contact handles as links and lists only the ticked messengers" do
    user = create_user
    user.update!(:instagram => "@player", :telegram_id => "player",
                 :on_signal => true, :on_viber => true)

    assign(:current_user, user)
    view.define_singleton_method(:current_user) { user }

    render

    # Normalised on save, so the link is built from a bare handle.
    expect(rendered).to include("https://instagram.com/player")
    expect(rendered).to include("https://t.me/player")
    expect(rendered).to include(I18n.t("messengers.signal"))
    expect(rendered).to include(I18n.t("messengers.viber"))
    expect(rendered).not_to include(I18n.t("messengers.whatsapp"))
  end

  it "omits the contact rows entirely when nothing is filled in" do
    user = create_user

    assign(:current_user, user)
    view.define_singleton_method(:current_user) { user }

    render

    expect(rendered).not_to include(I18n.t("users.index.instagram_label"))
    expect(rendered).not_to include(I18n.t("users.index.messengers_label"))
  end
```

- [ ] **Step 10: Extend the admin request spec**

In `spec/requests/admin_reporting_spec.rb`, in `"shows contact details to a superadmin"` (~line 105), add to the setup and assertions:

```ruby
      other.update!(:phone_number => "+995555123456", :icq_number => "123456789",
                    :telegram_id => "@somebody", :on_signal => true)
```

```ruby
      expect(response.body).to include("somebody")
      expect(response.body).to include(I18n.t("messengers.signal"))
```

- [ ] **Step 11: Run everything**

```bash
bundle exec rspec
bundle exec cucumber
```

Expected: **778 + 3 = 781 examples, 0 failures, 6 pending**, and cucumber unchanged at **234 scenarios / 2362 steps** — the profile feature still drives ICQ and Jabber, which are still present. Report actuals.

- [ ] **Step 12: Commit**

```bash
git add app/controllers/users_controller.rb app/views/users app/views/admin/users \
        app/helpers/application_helper.rb config/locales spec
git commit -m "Show Instagram, Telegram and messenger availability on all three profile screens

Brand names live in one shared messengers.* namespace rather than being
repeated per view, and are added to i18n_spec's known_legitimate_duplicates
allowlist: they are identical in all four locales by design, which is the
same reason admin.users.show.icq is already on that list.

The player's own profile renders a row only when it is populated; the admin
table renders a fixed shape, where a blank cell is information rather than
clutter.

ICQ and Jabber still render -- they come out next, once nothing reads them."
```

---

### Task 3: Remove ICQ and Jabber

**Files:**
- Create: `db/migrate/<timestamp>_remove_legacy_contacts_from_users.rb`
- Modify: `app/controllers/users_controller.rb`, `app/views/users/edit.html.erb`, `app/views/users/index.html.erb`, `app/views/admin/users/show.html.erb`
- Modify: `config/locales/{ru,en,uk,ka}.yml`
- Modify: `spec/i18n_spec.rb`, `spec/views/users_spec.rb`, `spec/controllers/users/update_spec.rb`, `spec/requests/admin_reporting_spec.rb`
- Modify: **`features/games/user-profile-view-and-edit.feature`** — the single authorised exception
- Modify: `features/games/steps/games_steps.rb`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything from Tasks 1 and 2.
- Produces: a `users` table with no `icq_number` or `jabber_id`.

**The data is destroyed.** `remove_column` with its type given is reversible, so `db:rollback` restores the columns — empty. This was decided explicitly by the repository owner; no export is taken first. Do not add one.

- [ ] **Step 1: Amend the feature file**

This is the only feature file this work may touch. Authorised by the repository owner on 2026-08-06.

In `features/games/user-profile-view-and-edit.feature`:

- Delete lines 5–6 of the feature description (`номер icq`, `jabber ID`).
- Scenario "Просмотр профиля игрока": change the step to
  `И данные пользователя "Тест Тестов" с паролем "testpass" такие "1988-05-13"`
  and delete the four table rows `| Номер ICQ |`, `| 123456789 |`, `| Jabber ID |`, `| 123456@test.kg|`.
- Scenario "Просмотр профиля капитана": change the step to
  `И данные капитана "Тест Тестов" с паролем "testpass" такие "1988-05-13", "0555 123456"`
  and delete the same four rows.
- Scenarios "Редактирование профиля игрока" and "Редактирование профиля капитана": delete the two
  `И ввожу ... в поле "Номер ICQ"` / `"Jabber ID"` lines and the same four table rows from each.

Leave every other line — including the commented-out `#И должен видеть ссылку` lines — exactly as it is.

- [ ] **Step 2: Update the two step definitions**

In `features/games/steps/games_steps.rb`, line 308 and line 319. Both are used **only** by the feature amended above — verified by grepping all of `features/` — so this has no blast radius.

```ruby
Then /^данные пользователя "([^"]+)" с паролем "([^"]+)" такие "([^"]+)"$/ do |nickname, password, date_of_birth|
  step %{залогинился как "#{nickname}" с паролем "#{password}"}
  step %{иду по ссылке "Профиль"}
  step %{иду по ссылке "Редактировать профиль..."}
  step %{ввожу "#{date_of_birth}" в поле "Дата рождения"}
  step %{нажимаю "Принять изменения"}
  step %{иду по ссылке "Выйти"}
end

Then /^данные капитана "([^"]+)" с паролем "([^"]+)" такие "([^"]+)", "([^"]+)"$/ do |nickname, password, date_of_birth, phone_number|
  step %{залогинился как "#{nickname}" с паролем "#{password}"}
  step %{иду по ссылке "Профиль"}
  step %{иду по ссылке "Редактировать профиль..."}
  step %{ввожу "#{date_of_birth}" в поле "Дата рождения"}
  step %{ввожу "#{phone_number}" в поле "Контактный телефон"}
  step %{нажимаю "Принять изменения"}
  step %{иду по ссылке "Выйти"}
end
```

- [ ] **Step 3: Remove the fields from the three views**

- `app/views/users/edit.html.erb` — delete the two `.field` divs for `:icq_number` and `:jabber_id`.
- `app/views/users/index.html.erb` — delete the two `<tr>` rows for `icq_label` and `jabber_label`.
- `app/views/admin/users/show.html.erb` — delete the two `<tr>` rows for `jabber` and `icq`.

- [ ] **Step 4: Remove the params**

In `app/controllers/users_controller.rb`, drop `:icq_number, :jabber_id` from `profile_params` and from the comment above it.

- [ ] **Step 5: Remove the locale keys**

Delete from **all four** of `config/locales/{ru,en,uk,ka}.yml`:

- `users.edit.icq_label`, `users.edit.jabber_label`
- `users.index.icq_label`, `users.index.jabber_label`
- `admin.users.show.jabber`, `admin.users.show.icq`

And delete these four now-dead entries from `known_legitimate_duplicates` in `spec/i18n_spec.rb`:

```
      users.edit.jabber_label
      users.index.jabber_label
      admin.users.show.jabber
      admin.users.show.icq
```

- [ ] **Step 6: Update the four affected specs**

- `spec/views/users_spec.rb` — delete the two `icq_label`/`jabber_label` expectations in the `users/edit` example and the two in the `users/index` example.
- `spec/controllers/users/update_spec.rb:11-12` — repoint the permitted-attribute proof at the new field:

```ruby
      perform_request(:as_user => @user, :params => { user: { nickname: @user.nickname, instagram: "player" } })
      expect(@user.reload.instagram).to eq("player")
```

- `spec/controllers/users/update_spec.rb:34` — update the comment enumerating the permitted list.
- `spec/requests/admin_reporting_spec.rb` — drop `:icq_number => "123456789"` from the setup and the `expect(response.body).to include("123456789")` assertion. The Telegram and Signal assertions added in Task 2 now carry that example.

- [ ] **Step 7: Write and run the migration**

```bash
bin/rails generate migration RemoveLegacyContactsFromUsers
```

```ruby
class RemoveLegacyContactsFromUsers < ActiveRecord::Migration[8.0]
  def change
    remove_column :users, :icq_number, :string
    remove_column :users, :jabber_id,  :string
  end
end
```

```bash
bin/rails db:migrate
bin/rails db:test:prepare
```

- [ ] **Step 8: Record the exception in CLAUDE.md**

In the "## The acceptance-suite rule" section, after the existing paragraph, add:

```markdown
**One authorised exception exists.** On 2026-08-06 the repository owner explicitly
authorised amending `features/games/user-profile-view-and-edit.feature` to drop the
ICQ and Jabber fields, which were retired from the product along with their database
columns (see `docs/superpowers/specs/2026-08-06-profiles-and-games-list-design.md`
§2.3). Four scenarios lost their ICQ/Jabber steps and table rows; the two step
definitions that carried those arguments were narrowed to match. The scenario count
did not change.

This is recorded so the amendment is traceable, **not** to soften the rule. The rule
stands exactly as written above: a feature file is changed only on an explicit,
recorded decision by the repository owner, never as a convenience and never to make
a failing test pass.
```

- [ ] **Step 9: Run everything, including a grep for stragglers**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
grep -rn "icq\|jabber" app/ config/ spec/ features/ db/schema.rb || echo "no references remain"
bin/rails zeitwerk:check
bundle exec rspec
bundle exec cucumber
```

Expected: the grep prints only the two `db/migrate/` files (the original 2010-era migration that added the columns, and the one removing them) — both are history and stay. `zeitwerk:check` prints `All is good!`. RSpec is **730 − 4 = 726 examples, 0 failures, 6 pending**. Cucumber is **234 scenarios (2 undefined) / 2362 steps** — unchanged, because the amendment removed steps from scenarios without removing any scenario.

If the cucumber step total has changed, the feature amendment removed or added a step line it should not have — compare against Step 1 rather than adjusting the expected number.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "Retire the ICQ and Jabber profile fields

Both networks are dead: ICQ shut down in 2024 and Jabber/XMPP has no
meaningful user base among players. The columns, form fields, profile rows,
admin rows and locale keys all go.

Amends features/games/user-profile-view-and-edit.feature, which drove both
fields across four scenarios. Feature files are read-only in this repository;
this single amendment was explicitly authorised by the repository owner on
2026-08-06 and is recorded in CLAUDE.md so it stays traceable. The rule is
not softened -- the scenario count is unchanged at 234.

The stored data is destroyed rather than exported first, decided explicitly."
```

---

## Definition of done

- `bundle exec rspec` — 777 examples, 0 failures, 6 pending (781 minus the 4 ICQ/Jabber assertions removed in Task 3). Report actuals.
- `bundle exec cucumber` — 234 scenarios (2 undefined), 2362 steps.
- `bin/rails zeitwerk:check` — `All is good!`.
- `grep -rn "icq\|jabber" app/ config/ spec/ features/` returns nothing.
- The profile edit form, the profile page and the admin user page each show Instagram, Telegram and the messenger list, and neither ICQ nor Jabber.
- CLAUDE.md records the feature amendment.
