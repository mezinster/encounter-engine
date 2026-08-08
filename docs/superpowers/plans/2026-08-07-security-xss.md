# Stored XSS Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the two stored cross-site-scripting holes that let any registered user run
JavaScript in other users' browsers, and stop the invitation page dumping every registered user's
email address into the page source.

**Architecture:** Both XSS holes are the same mistake in two places — a user-controlled string
crossing into a context where it is parsed as markup instead of displayed as text. Neither is fixed
by adding escaping at the source; both are fixed by changing the *sink* so the value can never be
parsed as markup at all. For the invitation page that means emitting the list as JSON in a
`<script type="application/json">` island and parsing it, instead of interpolating into a JS string
literal. For the hint poller it means building DOM nodes instead of concatenating an HTML string.

**Tech Stack:** Rails 8.0 (ERB views), jQuery 1.3.2, the vendored `jquery.autocomplete` plugin,
RSpec request specs.

## Global Constraints

- Ruby 3.3.12 via rbenv, **not on `PATH` in non-login shells**. Prefix every shell command with
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Never edit any file under `features/`** ending in `.feature`. Step definitions are editable;
  scenario files are not. No scenario in this plan's blast radius touches the invitation
  autocomplete or the hint poller, so no step definition needs changing either.
- Capture a green baseline with `bundle exec rspec` and `bundle exec cucumber` before starting.
  Compare against your own numbers, not against counts written in any document.
- Hash rockets (`:key => value`) are used throughout this codebase, including for symbol keys.
  Match the surrounding file rather than switching to `key:` syntax.
- User-facing strings are Russian; code, identifiers and comments are English.
- There is **no `config/initializers/` directory** in this repo and no Content-Security-Policy. Do
  not add either as part of this plan — a CSP is a separate, larger decision (it would require
  moving four inline `<script>` blocks to nonces first).

---

## File Structure

**Modified:**
- `app/views/invitations/new.html.erb` — replace the per-user `data.push({...})` loop with a JSON
  island plus a `JSON.parse`, and stop emitting email. Also supply escaping formatters so the
  autocomplete plugin's internal `.html()` render cannot be reached with markup.
- `public/javascripts/level_hint_updater.js` — `appendHint` builds DOM nodes instead of an HTML
  string.

**Created:**
- `spec/requests/invitations_autocomplete_spec.rb` — proves a hostile nickname cannot break out of
  the emitted JSON, and that emails are absent.
- `spec/assets/level_hint_updater_spec.rb` — a source guard for the poller (see Task 3 for why this
  is a guard rather than a behavioural test, and what that does and does not prove).

**Read but not modified:**
- `app/controllers/invitations_controller.rb:12,25` — sets `@all_users = User.all`. The query stays
  as it is in this plan; only what the view *emits* changes. (Narrowing the query to a search
  endpoint is noted as a follow-up in Task 1, not implemented here.)
- `public/javascripts/jquery.autocomplete.js:474-502, 668-671` — the plugin's parse loop and its
  `.html()` render. Understanding these two ranges is required to get Task 2's formatter contract
  right; do not modify the vendored plugin.

---

### Task 1: Emit the invitation autocomplete list as JSON, without emails

**Files:**
- Modify: `app/views/invitations/new.html.erb:7-34`
- Test: `spec/requests/invitations_autocomplete_spec.rb` (create)

**Interfaces:**
- Consumes: `@all_users` and `@current_user`, both already set by
  `InvitationsController#new` and `ApplicationController#set_current_user`.
- Produces: a `<script type="application/json" id="invitation-nicknames">` element whose text
  content is a JSON array of nickname strings. Task 2 consumes that element.

**Background you need:** the current line is

```erb
data.push({nick: '<%= user.nickname %>', email: '<%= user.email %>'});
```

`<%= %>` HTML-escapes, which is the wrong encoder inside a `<script>` block. It handles `'` and `<`
(and HTML entities are never decoded inside `<script>`, so those are genuinely safe) — but it does
**not** escape the backslash. A nickname ending in `\` escapes the closing quote, merges the two
string literals, and drops the *email* value into executable position. Registering with nickname
`evil\` and email `-alert(1)});//@x.com` (both pass the model's validations) yields
`data.push({nick: 'evil\', email: '-alert(1)});//@x.com'});`, which JavaScript parses as
`data.push({nick: <string> - alert(1)});`. It fires for every team captain who opens this page.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/invitations_autocomplete_spec.rb`:

```ruby
require "rails_helper"

# app/views/invitations/new.html.erb used to interpolate nickname and email
# directly into a JS string literal. ERB's html_escape does not escape "\",
# so a nickname ending in a backslash escaped the closing quote and merged
# the two literals, putting the email value in executable position.
describe "the invitation autocomplete payload", type: :request do
  let(:captain) { create_user }
  let(:team)    { create_team(:captain => captain) }

  before do
    captain.update!(:team => team)
    put login_path, :params => { :email => captain.email, :password => "1234" }
  end

  it "does not let a backslash nickname break out of the emitted payload" do
    hostile = create_user
    hostile.update!(:nickname => "evil\\")

    get new_invitation_path

    expect(response).to have_http_status(:ok)
    # The breakout signature: a backslash immediately before a closing quote
    # inside the script block.
    expect(response.body).not_to include("evil\\'")
    expect(response.body).not_to include("data.push(")
    # JSON escapes it as a doubled backslash, which no JS parser treats as
    # a quote escape.
    expect(response.body).to include('"evil\\\\"')
  end

  it "does not emit any user's email address" do
    other = create_user

    get new_invitation_path

    expect(response.body).not_to include(other.email)
    expect(response.body).not_to include(captain.email)
  end

  it "still offers the other users' nicknames" do
    other = create_user

    get new_invitation_path

    expect(response.body).to include('id="invitation-nicknames"')
    expect(response.body).to include(other.nickname)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/invitations_autocomplete_spec.rb
```

Expected: 3 examples, 3 failures. The first fails on `expected not to include "data.push("`, the
second on the email being present, the third on the missing `id="invitation-nicknames"`.

- [ ] **Step 3: Replace the interpolation loop with a JSON island**

In `app/views/invitations/new.html.erb`, replace lines 7-34 (the whole `<script>` block) with:

```erb
<%# The nickname list is emitted as JSON and parsed, never interpolated into a
    JS string literal. ERB's html_escape does not escape "\", so a nickname
    ending in a backslash used to escape the closing quote here and put the
    next value in executable position. to_json escapes the backslash, and
    escape_html_entities_in_json turns "<" into < so this block cannot be
    terminated early either. Emails are deliberately absent: this page is
    reachable by any team captain, and captaincy is self-service, so shipping
    the whole user table's email addresses here handed out the instance's
    complete login-identifier list. %>
<script type="application/json" id="invitation-nicknames">
  <%= raw @all_users.reject { |user| user == @current_user }.map(&:nickname).to_json %>
</script>

<script>

    $(document).ready(function() {

        var escapeHtml = function(value) {
            return String(value).replace(/[&<>"']/g, function(character) {
                return {
                    '&': '&amp;', '<': '&lt;', '>': '&gt;',
                    '"': '&quot;', "'": '&#39;'
                }[character];
            });
        };

        var data = JSON.parse(document.getElementById("invitation-nicknames").textContent);

        $("#invitation_recepient_nickname").autocomplete(data, {
            minChars: 1,
            width: 310,
            matchContains: "word",
            autoFill: false,
            // jquery.autocomplete.js:671 renders each row with .html(), so
            // formatItem must return escaped markup. formatMatch and
            // formatResult must NOT escape -- their return values are used for
            // matching and for the value written into the field.
            formatItem: function(row) {
                return escapeHtml(row[0]);
            },
            formatMatch: function(row) {
                return row[0];
            },
            formatResult: function(row) {
                return row[0];
            }
        });
    })

</script>
```

Two details that are easy to get wrong and will not fail loudly:

1. `row` is an **array**, not an object. `jquery.autocomplete.js:477` wraps a plain string item as
   `[string]`, so the accessor is `row[0]`, not `row.nick`.
2. `formatMatch` must be supplied explicitly. `jquery.autocomplete.js:29` falls back to
   `formatItem` when `formatMatch` is absent — which would make the *escaped* string the value used
   for matching and for filling the field, so typing `a&b` would stop matching a user actually
   named `a&b`.

- [ ] **Step 4: Run the test to verify it passes**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/invitations_autocomplete_spec.rb
```

Expected: 3 examples, 0 failures.

- [ ] **Step 5: Run the existing invitation coverage**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/views/invitations_spec.rb spec/controllers/invitations
bundle exec cucumber features/invitations
```

Expected: all green. `spec/views/invitations_spec.rb:23-24` asserts on nicknames only, and no
`.feature` file exercises the autocomplete, so nothing here should move.

- [ ] **Step 6: Commit**

```bash
git add app/views/invitations/new.html.erb spec/requests/invitations_autocomplete_spec.rb
git commit -m "Emit the invitation autocomplete as JSON, without emails

A nickname ending in a backslash escaped the closing quote of the JS string
literal this view interpolated into, merging it with the following literal and
putting the email value in executable position. ERB's html_escape covers
& \" ' < > and not the backslash, so HTML escaping never protected this
context. The list is now a JSON island parsed at runtime.

Emails are dropped at the same time: the page is captain-reachable, captaincy
is self-service, and email is this app's login identifier, so the payload was
a complete valid-username list for anyone who created a team."
```

**Follow-up, deliberately not done here:** `@all_users = User.all` still loads and ships the entire
user table on one page. Replacing it with a server-side prefix-search endpoint is the better shape,
but it changes a controller contract and deserves its own change.

---

### Task 2: Prove the autocomplete render cannot be reached with markup

**Files:**
- Test: `spec/requests/invitations_autocomplete_spec.rb` (extend the file created in Task 1)

**Interfaces:**
- Consumes: the `formatItem`/`formatMatch`/`formatResult` block written in Task 1.
- Produces: nothing consumed by later tasks.

**Why this task exists separately:** Task 1's JSON island fixes the *server-side* breakout. It does
not by itself fix the plugin's own sink — `jquery.autocomplete.js:671` does
`$("<li/>").html(options.highlight(formatted, term))`. Before Task 1, a nickname containing `<img>`
arrived at that line already HTML-entity-encoded by ERB and therefore rendered as inert text; that
was an accident of double-encoding, not a defence. Correct JSON encoding removes the accident, so
the `formatItem` escaping added in Task 1 is what keeps that sink closed. This task pins that
behaviour so a future edit cannot silently drop it.

- [ ] **Step 1: Write the failing test**

Append to `spec/requests/invitations_autocomplete_spec.rb`, inside the same `describe` block:

```ruby
  # jquery.autocomplete.js:671 renders each suggestion with .html(). Correct
  # JSON encoding (Task 1) delivers a real "<" to that sink, so formatItem
  # must escape. Before the JSON island, ERB's entity-encoding happened to
  # neutralise this -- an accident, not a control.
  it "escapes suggestion markup before the plugin renders it" do
    create_user.update!(:nickname => "<img src=x onerror=alert(1)>")

    get new_invitation_path

    expect(response.body).to include("escapeHtml")
    expect(response.body).to include("formatItem")
    # The raw nickname reaches the browser inside the JSON island (correct --
    # JSON.parse yields a string, not markup), but must never appear as live
    # markup outside it.
    expect(response.body).not_to include("<img src=x onerror=alert(1)>")
  end
```

- [ ] **Step 2: Run it and confirm it passes on Task 1's implementation**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/invitations_autocomplete_spec.rb
```

Expected: 4 examples, 0 failures. Note the JSON island encodes `<` as `<`, which is why the
raw markup string does not appear in the body.

If it fails on the last expectation, `escape_html_entities_in_json` has been disabled somewhere —
stop and investigate rather than weakening the assertion.

- [ ] **Step 3: Confirm the guard actually guards**

Temporarily delete the `formatItem` function from `app/views/invitations/new.html.erb`, re-run the
spec, and confirm it fails. Restore the function. This is the only way to know the test is not
vacuous.

- [ ] **Step 4: Commit**

```bash
git add spec/requests/invitations_autocomplete_spec.rb
git commit -m "Pin the autocomplete escaping contract

Correct JSON encoding removes the accidental double-escaping that used to
neutralise the plugin's internal .html() render, so formatItem's escaping is
now the thing keeping that sink closed. Assert it."
```

---

### Task 3: Build hint nodes in the DOM instead of concatenating markup

**Files:**
- Modify: `public/javascripts/level_hint_updater.js:61-73`
- Test: `spec/assets/level_hint_updater_spec.rb` (create)

**Interfaces:**
- Consumes: `data.hint_num` and `data.hint_text` from `GamePassingsController#get_current_level_tip`
  (`app/controllers/game_passings_controller.rb:57-67`). That JSON contract does not change.
- Produces: nothing consumed by later tasks.

**Background:** the play screen renders hints two ways and only one of them escapes.
`app/views/game_passings/show_current_level.html.erb:30` uses `<%= %>` and is safe. The poller
concatenates the author's raw hint text into an HTML string and hands it to jQuery `.append()`,
which parses it as markup — and jQuery 1.3.2 additionally `globalEval`s any `<script>` it finds.
Rails' `escape_html_entities_in_json` does not help: it emits `<` on the wire, and `JSON.parse`
restores a literal `<` before the value reaches the sink. Any registered user can create a game and
therefore author hints. Because the ERB path escapes, a manual "does my hint display as text?"
check reports *safe* — the payload only fires when a hint unlocks while the page is open, which is
the normal path for every hint after the first.

**On testing:** this repository has no JavaScript test runner, and Cucumber runs on `rack_test`
(no JS engine), so there is no way to execute this code in the suite. The spec below is a **source
guard**: it asserts the dangerous construct is absent and the safe one present. It proves the fix
has not been reverted; it does not prove the poller works. Verify behaviour manually in Step 5 —
that step is not optional.

- [ ] **Step 1: Write the failing test**

Create `spec/assets/level_hint_updater_spec.rb`:

```ruby
require "rails_helper"

# public/javascripts/level_hint_updater.js injects hint text that arrives from
# GamePassingsController#get_current_level_tip. Hint text is author-written
# free text and any registered user can become an author, so it is untrusted.
# jQuery .append() with a STRING parses it as markup (and jQuery 1.3.2 evals
# any <script> it finds), which made every hint a stored-XSS vector against
# every playing team. There is no JS runner in this suite, so this is a source
# guard, not a behavioural test.
describe "the level hint updater", type: :model do
  let(:source) { Rails.root.join("public/javascripts/level_hint_updater.js").read }

  it "does not concatenate hint text into an HTML string" do
    expect(source).not_to match(/append\([^)]*\+\s*hintText/)
    expect(source).not_to include("</legend>' + hintText")
  end

  it "builds the hint node as text" do
    expect(source).to include("createTextNode(hintText)")
  end

  it "keeps the pinned playbar hint on textContent" do
    expect(source).to include("pinnedText.textContent = hintText")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/assets/level_hint_updater_spec.rb
```

Expected: 3 examples, 2 failures (the third already passes — line 69 is correct today, and the
spec pins it so a rewrite does not lose it).

- [ ] **Step 3: Rewrite `appendHint`**

Replace `public/javascripts/level_hint_updater.js:61-73` with:

```javascript
    ,appendHint = function(hintNum, hintText) {
        // Nodes, not an HTML string: hint text is author-written and reaches
        // this function raw from /play/:game_id/tip. jQuery .append() with a
        // string parses it as markup, so concatenating here made every hint a
        // stored-XSS vector against every playing team. The server-rendered
        // path (show_current_level.html.erb) escapes, so text is the correct
        // and matching behaviour. "card" matches the class that view puts on
        // its own fieldset.
        var fieldset = document.createElement("fieldset");
        fieldset.className = "card";

        var legend = document.createElement("legend");
        legend.textContent = "Подсказка #" + hintNum;

        fieldset.appendChild(legend);
        fieldset.appendChild(document.createTextNode(hintText));

        $hintsContainer.append(fieldset);

        // The playbar shows the newest hint so a stuck player does not have to
        // scroll for it. Guarded: this element only exists on the play screen,
        // and the poller must keep working if it is ever absent.
        var pinnedText = document.getElementById("PlaybarHintText");
        if (pinnedText) {
            pinnedText.textContent = hintText;
            var pinnedWrap = document.getElementById("PlaybarHint");
            if (pinnedWrap) { pinnedWrap.removeAttribute("hidden"); }
        }
    }
```

Note the `</br>` in the old markup is dropped — it was never valid HTML (the correct void element
is `<br>`), and the fieldset now closes the block on its own.

- [ ] **Step 4: Run the test to verify it passes**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/assets/level_hint_updater_spec.rb
```

Expected: 3 examples, 0 failures.

- [ ] **Step 5: Verify behaviour manually — required, not optional**

The source guard cannot tell you the poller still works. Do this:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails server
```

Then, in a browser: create a game with one level, add a hint with `delay` of about 30 seconds and
text `<img src=x onerror="alert(1)">`, register a second account into a team, accept the entry,
start the game, open the play screen as the player, and wait for the countdown to elapse.

Expected: the hint appears as the literal text `<img src=x onerror="alert(1)">` in a new fieldset,
no alert fires, the countdown restarts (or "Подсказок больше не будет" appears if it was the last
hint), and the playbar shows the same text. Before this fix, the alert fires.

- [ ] **Step 6: Run the full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
```

Expected: your Step-0 baseline plus the 7 new examples, no failures. Cucumber is unchanged —
`rack_test` never executes this file.

- [ ] **Step 7: Commit**

```bash
git add public/javascripts/level_hint_updater.js spec/assets/level_hint_updater_spec.rb
git commit -m "Build live hint nodes as text, not markup

The hint poller concatenated author-written hint text into an HTML string and
passed it to jQuery .append(), which parses markup -- and jQuery 1.3.2 evals
any <script> it finds. escape_html_entities_in_json does not help: JSON.parse
restores a real '<' before the value reaches the sink. The server-rendered
path already escapes, so text nodes are the matching behaviour.

Fixing this in the controller instead would leave the sink armed for the next
caller and double-escape the server-rendered path."
```

---

## Definition of done

- `bundle exec rspec` and `bundle exec cucumber` match the Step-0 baseline, plus 7 new examples.
- The manual browser check in Task 3 Step 5 has actually been performed and no alert fired.
- `git log` shows three commits, each independently revertable.
- Neither `data.push(` nor `+ hintText` appears anywhere in `app/views/` or `public/javascripts/`.
