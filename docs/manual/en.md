# User manual

How to use encounter-engine. Three sections, one per role:

- **[For players](#for-players)** — you take part in games.
- **[For game authors](#for-game-authors)** — you create and run games.
- **[For administrators](#for-administrators)** — you look after the whole server.

The roles stack: a game author is an ordinary player who created a game. There is
nothing to sign up for separately.

Russian version: [ru.md](ru.md). Running your own server: [deployment.en.md](deployment.en.md).

---

## General

### Signing up and signing in

Sign up with "Sign up" in the left menu (`/signup`). All you need is a **nickname and
an e-mail address**: you do not choose a password, the server generates one and mails
it to you. Your nickname is visible to other players; your e-mail is not, except to
the server administrator.

You are signed in immediately after signing up. **Change the mailed password to one of
your own** in your profile — the letter asks you to. It is temporary in spirit, though
nothing expires it.

Sign in with "Log in" (`/login`), leave with "Log out".

**Forgotten passwords** — "Forgot your password?" on the sign-in page. A time-limited
link is sent to the address you give, and that link sets a new password. The server
answers the same way whether or not the address exists, so the form cannot be used to
find out who is registered.

Signups and password-reset requests are rate-limited per IP address. If you hit "too
many attempts" on shared Wi-Fi, wait and try again.

### Profile

"Profile" in the left menu. What lives here:

- **your nickname** — how other players see you;
- **contacts** — phone, Instagram, Telegram, which messengers you are on (Telegram,
  WhatsApp, Viber, Signal, MAX) and your date of birth. All optional. Only the server
  administrator can see them — they are never shown to other players;
- **interface language** — see below;
- **timezone** — see below;
- **changing your password** — the new password, its confirmation, and **your current
  password**. Without the current one the change is refused: otherwise anyone who got
  to an unlocked browser could take the account permanently.

### Timezone

You can pick your own timezone in your profile. Every date and time — game start,
finish times, log entries — is then shown in it rather than in the server's zone. Leave
it unset and the server's zone is used.

Screens where the time matters (logs, results) say which zone they are using: "Times
shown in …", so you never have to guess whose clock you are reading.

### Interface language

The language switcher is in the page header. Russian, English, Ukrainian, Georgian,
Turkish, Belarusian and Polish are available.

When you are signed in, your choice is stored in your profile and follows you across
devices. For a one-off change, add `?locale=en` to the address — that beats both your
profile and the server default.

**Important:** the switcher changes the interface only — menus, buttons, system
messages. Task text, game titles and descriptions are written by the author and are
always shown exactly as written. Multilingual games have a separate switcher for the
task language — see [Task language](#task-language).

Next to it is a "Theme" button, which toggles between the light and dark appearance.

---

## For players

### Your team

Games are played in teams. Until you are in one, you cannot play.

There are three ways in:

**Create your own.** "Create a team" in the left menu. Whoever creates it becomes the
captain.

**Accept an invitation.** A captain invites you by nickname. The invitation appears on
your dashboard, where you can accept or decline it.

**Ask to join.** "All teams" (`/teams`) lists them, each with an "Apply to join"
button. Your application lands in the captain's team room, and they accept or decline.

### The team room

"Team room" in the left menu — the roster, applications to join (for the captain), and
everything that can be done to the team:

| Action | Who can |
|---|---|
| Invite members | the captain |
| Accept/decline an application to join | the captain |
| Hand over captaincy | the captain, if anyone else is on the team |
| Leave the team | any member; a captain must hand over first, or be the last one left |

The captain differs from other members in three ways: only the captain can apply for a
game, only the captain can withdraw the team mid-game, and only the captain manages
the roster.

> **While the team is out on a course, the roster is frozen.** Nobody can leave, hand
> over captaincy, apply to another team or be accepted into one. Otherwise a run in
> progress would be left with nobody to own it.

### Applying for a game

"All games in this domain" in the left menu lists them. A game's page shows the
description, start time, registration deadline and the maximum number of teams.

The captain applies from the game's page. The application then moves through these
states:

| Status | Meaning |
|---|---|
| New | Submitted, the author has not answered yet |
| Accepted | The team is in |
| Rejected | The author declined |
| Recalled | The captain withdrew the application before the author answered |
| Canceled | The captain pulled out after the application had been accepted |

You apply not to "the game" in the abstract but to its current **run** — see the next
section.

### Runs

The same game can be put on more than once — on Saturday and again on Sunday, or six
months later for a new crowd. Each such outing is a **run**.

What that means for a player:

- **each run has its own start time, registration deadline and team limit.** A game's
  page shows the current run: the one taking applications, or the one under way;
- **results and logs are counted within a run.** Your place is among the teams that
  ran alongside you, not among everyone who has ever played the game;
- if there has been more than one run, the results and log pages grow a "Runs:"
  switcher, so you can look back at how a previous one went.

New runs are opened by the server administrator, and only once the previous one has
finished.

### Playing

The game starts at its appointed time. Until then the play page will not let you in —
that is expected.

To play: from the game's page, or directly at `/play/GAME_NUMBER`.

The task page shows:

- **the task text** — what to find or do;
- **a "Code" field** — where you enter the code you found. On tasks with options you
  get a list to choose from instead;
- **hints** — these appear on their own, on a timer that starts when your team reaches
  the task. A countdown shows the time to the next one;
- **a code counter**, if the task has several codes and all of them are needed.

The entry field, the countdown to the next hint and the latest hint are pinned to the
bottom of the screen: however much task text and however many hints pile up, you never
have to scroll to answer.

Codes are matched ignoring capitalisation and surrounding spaces. A single code can
have several accepted spellings — the author decides.

**How many codes a task needs is up to the author.** A task with several codes runs in
one of two modes: "any one code passes" or "all codes must be found". In the second
case you get a counter, "Correct codes entered: N of M". Any one code is the default.

Any team member can enter codes, not just the captain. Progress is shared.

### Tasks with options

A task may offer a choice instead of asking for a code — then you get a list rather
than a text field, and on some tasks more than one option is correct.

**A wrong choice can carry a penalty**, set by the author in minutes. The penalty does
not eat your time on the task and does not bring hints closer: it is added to your
final time at the finish. It is charged **every time**, including for re-picking an
option you already tried — otherwise a team could walk the whole option space for the
price of a single mistake.

Your accumulated penalty is shown on the task page as soon as there is one.

There is no penalty for a wrong typed **code** — penalties exist only on tasks with
options.

### Task language

If a game is multilingual, the task page has its own language switcher for task
content. It is independent of the interface language: your interface can be in English
while the tasks are in Russian.

If a particular task has not been translated into your chosen language yet, the
original is shown with a note saying so. Text is never replaced by machine translation.

### Pauses

The organiser can pause a game — for a thunderstorm, say, or a closed street. A
message then appears above your task.

While paused:

- **hint timers are stopped.** No new hints will appear, and the pause does not eat
  into your allowance — when play resumes, the countdown continues from exactly where
  it stopped;
- **codes are not accepted**, and the entry field is removed altogether;
- the task stays visible, so you can keep thinking about it.

Stay where you are and wait for play to resume.

### Withdrawing from a game

The captain can pull the team out with "Leave the race".

**This is one-way: the team cannot put itself back in.** Only the game's author or a
server administrator can reinstate you — ask them if it was a misclick.

### Results

After finishing, a team sees the run's table: place, team, finish time, penalty and
total.

**Places are ranked on the total, not on the finish time.** A team that collected
penalties on option tasks places below one that took longer and made no mistakes.

The full answer log for the whole game is available to teams that **completed** it (not
to teams that withdrew) and to the game's author. If there has been more than one run,
a run switcher sits at the top.

---

## For game authors

### Creating a game

"Create a game >>" on your dashboard. You will need a title, a description, a start
time, a registration deadline and a maximum number of teams.

The **"Draft?"** checkbox is the important one:

- **a draft** is visible only to you, so you can prepare everything in peace;
- **clear the checkbox and the game is published**, visible to everyone and open for
  applications.

A published game cannot be edited once it has started.

The start time, deadline and team limit belong to the game's current **run**. While
there is only one run — as there is for most games — you will not notice the
difference: it is the same form.

### Tasks, codes and hints

Tasks are added from the game's page ("Add a new task"). The arrows reorder them.

A task has:

- **a title and text** — what the player sees;
- **codes** — the right answers. Each code can have several accepted spellings, which
  count as equivalent;
- **how codes count** — for a task with several: "any one code passes" (the default)
  or "all codes must be found";
- **options** — if the player should pick from a list instead of typing (see below);
- **a penalty for a wrong answer** in minutes, which only applies to tasks with
  options;
- **hints** — each with a delay in minutes from the moment a team reaches the task.

Hints are the main pacing tool. A team stuck on a task gets them one after another; a
team that has moved on gets none.

### Options

"Answer options" on a task's page. Once a code has options, players pick from a list
instead of typing. More than one option can be correct — and then only the exact set
counts: there is no "partly right" here, because the score in this game is time.

The penalty for a wrong choice is set on the task itself, in minutes, and is added to
the team's final time.

### Importing tasks in bulk

"Import levels in bulk" on the game's page saves entering two dozen tasks by hand.
Paste the lot: a line (or several in a row) is the task text, and the answers follow.

```
Walk to the corner of Kievskaya and Chuy.
There is a plaque on the wall with the year it was built.
A) 1967

What is the capital of Belarus?
A) Brest
B) Grodno
C) *Minsk
```

- one answer of the form `A) CODE` — an ordinary task with a code;
- two or more — a task with options; mark the correct one with an asterisk, or use two
  asterisks when several are correct;
- **a line of the form "letter) text" always reads as an answer**, even in the middle
  of a task. Task text cannot begin with one.

Before anything is added you get a preview: what will be added, and what was skipped
as already present. Importing into a game that has already started is not allowed.

### Multilingual games

A game has a primary language and a list of languages it is available in. Editing then
grows one tab per declared language. Options are translated separately, as a list, on
the options page.

Codes are shared across languages. If an answer is spelled differently in another
language, add each spelling as another accepted code.

Two rules:

1. **A game with an incomplete translation cannot be published.** If it declares
   Russian and English and some field is untranslated, publishing is refused and you
   are shown exactly which fields are missing.
2. **The primary language cannot be changed once translations exist** — otherwise the
   text columns would still hold one language while the game declared another.

### Applications

Applications appear on the game's page. Accept or reject each one. The number of
accepted teams is capped by the maximum you set for the current run.

### Testing

**"Start testing"** puts the game into test mode: it starts immediately and you can
play it yourself — in test mode the author is allowed into their own game.

**"Finish testing"** returns the game to draft and restores its original start date.

> **Careful:** finishing a test **deletes every passing and log** for that game. That
> is the point — it clears the traces of the test before the real thing. Do not press
> it on a game that has really been played.

If testing will not start, you are told why — most often an incomplete translation.

### Watching a game

From the games list, on your own game:

| Link | What it shows |
|---|---|
| (statistics) | Every team: which task they are on and how long they have been there |
| (live channel) | Every code entered across the game, as it happens |
| (answer log) | The full log, all teams and all tasks |

The statistics page is the main screen during a game. Interventions live there too.

All three screens name the game and the run, show how many teams and tasks are
involved, and say which timezone the times are in. The full log is paged. If there has
been more than one run, a "Runs:" switcher at the top gets you back to the previous
one.

### Intervening in a running game

On your own game's statistics page you can:

**Pause / resume the game.** A pause stops every team's hint timer and refuses codes.
When you resume, each team gets back exactly the remaining time it had. Use it for
storms, emergencies, a closed street.

**Move a team to another task.** For a team stuck on a task that has broken: the code
does not match, the location is unreachable. The hint timer on the new task starts
over, and codes entered on the current task are cleared.

**Reinstate a team.** Undoes "Leave the race" when a captain misclicked. The hint
timer starts over.

**Reset the clock.** Zeroes the time on a task, if hints went out at the wrong moment.

**Change how codes count on a task** — "Any one code passes" / "All codes must be
found". This rescues a multi-code task where one of the locations turned out to be
unreachable: instead of dealing with every team separately, you soften the task itself
for everyone at once.

All of this works while the game is running, including while it is paused. Answer
history (the logs) is never changed by an intervention — it stays an honest record of
what the team actually entered.

### Ending a game

**"END THE GAME"** ends it for every team at once.

**It cannot be undone** — no team can enter another code. Use it when the game really
is over.

A finished game can be put on again: a server administrator opens a new run and
registration starts afresh. Tasks, codes and hints stay as they are, and the previous
run's results are kept separately.

A game ended by mistake can be resumed by an administrator.

### Transferring authorship

"Transferring authorship" on the game's page — enter the new author's nickname. The
game becomes theirs entirely: they edit it, decide applications and intervene.

Authorship cannot be transferred while the game is running, or while editing is frozen
by an administrator.

### Deleting a game

A game can be deleted **only if nobody has played it yet**. As soon as a single passing
exists, deletion is refused: it would leave teams' logs and results pointing at
nothing.

For a game that has been played there is unpublishing instead — ask an administrator.

---

## For administrators

A server administrator (superadmin) is responsible for every game, not only their own.

Rights are granted by another administrator. The very first administrator is appointed
from the server console — otherwise there would be nobody to grant them (see the
[installation guide](deployment.en.md#6-the-first-administrator)).

### Where things are

Once you have the rights, an **Administration** section appears in the left menu:

| Item | Address | What is there |
|---|---|---|
| Overview | `/admin` | A summary: games by status, totals for players/teams/games, applications |
| All games | `/admin/games` | Every game on the server, with actions |
| Players | `/admin/users` | Everyone registered |
| Action log | `/admin/audit` | Who did what |

Two more are linked from the overview: **All teams** (`/admin/teams`) and **Rate
limits** (`/admin/settings`).

### Other players' privileges

A player's page (`/admin/users/NUMBER`) has "Make an administrator" and "Revoke
administrator rights".

Two limits, and neither can be lifted:

- **you cannot revoke your own rights** — that guards against locking yourself out by
  accident, and guarantees that every demotion has a second party in the log;
- **you cannot revoke the last administrator's rights** — the server must never be
  left without one. This rule holds in the console too.

A player's page shows their contacts — phone, Instagram, Telegram, messengers, date of
birth. They are deliberately absent from the list: seeing someone's contacts takes a
conscious visit to their page.

### Actions on players

On the same page:

**Move to a team.** For when someone cannot move themselves — the captain has vanished
and the team has fallen apart.

**Delete the account.** Permanently. You cannot delete yourself, the last
administrator, a captain (give their team another captain first), or **an author of
games** — that would take away games other people played.

**Anonymise the account.** What you do instead of deleting an author: the person
disappears from listings and from view, and their games stay where they are.

A player cannot be moved while either team — the one they are leaving or the one they
are joining — is out on a course.

### Actions on teams

On `/admin/teams`: **set a captain** (when the previous one has vanished and there is
nobody to hand over) and **delete a team** — only one that is empty and has never
played.

### Actions on games

On `/admin/games`:

**Unpublish / Publish.** Takes the game out of the public listings and closes it to
outsiders. The author and administrators still see it.

> Teams **already playing** carry on — unpublishing does not throw people off a course
> in the middle of the city. That is deliberate.

**Freeze / Unfreeze.** The author can no longer edit the game, start or finish
testing, delete it, end it or transfer authorship. Use it when you need to establish
what happened and keep the state still.

Freezing does not stop the author **looking at** their game and its logs — only
changing them. It does not restrict administrators.

**Resume.** Undoes ending a game, when the author pressed "END THE GAME" too early.

**Change author.** Transfer of authorship without asking the current author — for when
they are unreachable or unwilling. Unlike the author's own transfer, this works on a
frozen game, and on a running one.

**Open a new run.** Putting the same game on again — see below.

**Applications (N).** The team-admission console — see below.

**Delete.** Same rule as for the author: only if nobody has played it. Otherwise,
unpublish.

### A new run

"Open a new run" on `/admin/games` — a form with a start time, a registration deadline
and a team limit. The game then takes applications again, while the previous results
stay where they are under their own run number.

Two conditions:

- **the previous run must be finished.** A new run cannot be opened over a running one;
- **the game must have at least one task.**

The start time has to be in the future, and the registration deadline before it.

### Applications for a game

"Applications (N)" next to a game on `/admin/games` — a screen showing who has applied
to the current run, where you can accept or reject without being the author.

This is for when the author is unreachable and the game is about to start: previously
an administrator would have had to take the authorship over wholesale.

The screen shows the current run's applications only, and says which run that is.

### Rate limits

`/admin/settings` — how many signups and how many password-reset requests one IP
address may make in a given window. `0` disables a limit.

The defaults suit an ordinary server. Raising them is rarely necessary; lowering them
is for when someone is hammering the door. Bear in mind that one address may be a
whole club or a whole dormitory.

### Intervening in other people's games

Everything in [Intervening in a running game](#intervening-in-a-running-game) is
available to an administrator in **any** game, not just their own: pausing, moving a
team, reinstating one, resetting the clock, softening a task's code rule.

That is what the rights are for: the author may be unreachable while a team stands in
the middle of the city.

### The action log

`/admin/audit` — who, what, when, and to which object.

**What is logged:** an administrator's actions in **someone else's** game, actions on
players and teams, opening a run, changing an author, changing settings, and granting
or revoking rights.

**What is not:**

- an author's actions in **their own** game. That is ordinary work, not administration;
  logging it would drown the log in routine;
- views. The log answers "who changed this", not "who looked at it" — including
  looking at a player's contacts;
- appointing the very first administrator from the console. There is no way around
  this: the log is kept by the web application, and the console goes around it.

Log entries are **never edited or deleted** — not from the interface, not by any other
route. A log that its subject can edit is not a log.

A game's title or a player's nickname is stored in the log **as it was at the time**.
So an entry about a deleted game still names it, instead of showing a number that
leads nowhere.

---

## When something goes wrong

| Symptom | What it means |
|---|---|
| "The organiser has paused the game" | A pause. Wait; hints are frozen and you lose no time |
| The play page will not let you in before the start | The game has not started — that is normal |
| A password was mailed but no letter arrived | Check spam. You can get a new one via "Forgot your password?" |
| "Too many attempts" when signing up | The per-IP rate limit. Wait, or ask an administrator to raise it |
| The profile will not change your password | It also needs your current password — that is the protection against a borrowed browser |
| A team withdrew by mistake | The game's author or an administrator can reinstate it |
| Cannot leave a team or hand over captaincy | The team is out on a course. The roster unfreezes afterwards |
| The times on screen are not the times on your watch | Check the timezone in your profile; log screens name the zone they use |
| Testing will not start | Most likely an incomplete translation — the reason is shown |
| A game will not delete | It has been played. Unpublish it instead |
| The author cannot edit a game | Either it has started, or editing is frozen by an administrator |
| A new run will not open | The previous one is not finished, or the game has no tasks |
| A lower place than expected | Penalties for wrong options are added to the finish time |
