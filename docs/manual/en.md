# User manual

How to use encounter-engine. Three sections, one per role:

- **[For players](#for-players)** — you take part in games.
- **[For game authors](#for-game-authors)** — you create and run games.
- **[For administrators](#for-administrators)** — you look after the whole server.

The roles stack: a game author is an ordinary player who created a game. There is
nothing to sign up for separately.

Russian version: [ru.md](ru.md).

---

## General

### Signing up and signing in

Sign up with "Sign up" in the left menu (`/signup`). You need a nickname, an e-mail
address and a password. Your nickname is visible to other players; your e-mail is
not, except to the server administrator.

Sign in with "Log in" (`/login`), leave with "Log out".

### Profile

"Profile" in the left menu. Phone, Jabber, ICQ and date of birth live here too.
These are optional, and only the server administrator can see them — they are never
shown to other players.

### Interface language

The language switcher is in the page header. Russian, English, Ukrainian and
Georgian are available.

When you are signed in, your choice is stored in your profile and follows you across
devices. For a one-off change, add `?locale=en` to the address — that beats both
your profile and the server default.

**Important:** the switcher changes the interface only — menus, buttons, system
messages. Task text, game titles and descriptions are written by the author and are
always shown exactly as written. Multilingual games have a separate switcher for the
task language — see [Task language](#task-language).

---

## For players

### Your team

Games are played in teams. Until you are in one, you cannot play.

**Create your own:** "Create a team" in the left menu. Whoever creates it becomes
the captain.

**Join someone else's:** the captain invites you by nickname. The invitation appears
on your dashboard, where you can accept or decline it.

The captain differs from other members in two ways: only the captain can apply for a
game, and only the captain can withdraw the team mid-game.

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

### Playing

The game starts at its appointed time. Until then the play page will not let you in
— that is expected.

To play: from the game's page, or directly at `/play/GAME_NUMBER`.

The task page shows:

- **the task text** — what to find or do;
- **a "Code" field** — where you enter the code you found;
- **hints** — these appear on their own, on a timer that starts when your team
  reaches the task. A countdown shows the time to the next one;
- **a code counter**, if the task has more than one code.

Codes are matched ignoring capitalisation and surrounding spaces. A single code can
have several accepted spellings — the author decides.

When a task has several codes, it is finished once all of them are in. The team then
moves to the next task and the hint timer starts over.

Any team member can enter codes, not just the captain. Progress is shared.

### Task language

If a game is multilingual, the task page has its own language switcher for task
content. It is independent of the interface language: your interface can be in
English while the tasks are in Russian.

If a particular task has not been translated into your chosen language yet, the
original is shown with a note saying so. Text is never replaced by machine
translation.

### Pauses

The organiser can pause a game — for a thunderstorm, say, or a closed street. A
message then appears above your task.

While paused:

- **hint timers are stopped.** No new hints will appear, and the pause does not eat
  into your allowance — when play resumes, the countdown continues from exactly
  where it stopped;
- **codes are not accepted;**
- the task stays visible, so you can keep thinking about it.

Stay where you are and wait for play to resume.

### Withdrawing from a game

The captain can pull the team out with "Leave the race".

**This is one-way: the team cannot put itself back in.** Only the game's author or a
server administrator can reinstate you — ask them if it was a misclick.

### Results

After finishing, a team sees its result and its place. The full answer log for the
whole game is available to teams that **completed** it (not to teams that withdrew)
and to the game's author.

---

## For game authors

### Creating a game

"Create a game >>" on your dashboard. You will need a title, a description, a start
time, a registration deadline and a maximum number of teams.

The **"Draft?"** checkbox is the important one:

- a **draft** is visible only to you, so you can prepare in peace;
- **clear the checkbox and the game is published** — visible to everyone and open
  for applications.

A published game cannot be edited once it has started.

### Tasks, codes and hints

Add tasks from the game's page ("Add a new task"). Reorder them with the arrows.

A task has:

- **a title and text** — what the player sees;
- **codes** — the correct answers. A task can have several, in which case it is only
  finished when all of them are in. Each code can have several accepted spellings,
  treated as equivalent;
- **hints** — each with a delay in minutes from the moment a team reaches the task.

Hints are your main tool for controlling pace. A team stuck on a task receives them
one after another; a team that is ahead receives none.

### Multilingual games

A game has a primary language and a list of languages it is offered in. While
editing, you get one tab per declared language.

Two rules:

1. **A game with incomplete translations cannot be published.** If you declare
   Russian and English but leave a field untranslated, publishing is refused and you
   are shown exactly which fields are missing.
2. **The primary language cannot be changed once translations exist** — otherwise
   the text columns would hold one language while the game claimed another.

### Applications

Applications appear on the game's page. Accept or reject each one. The number you can
accept is capped by the maximum you set.

### Testing

**"Start testing"** puts the game into test mode: it starts immediately and you can
play it yourself — in test mode an author is allowed to play their own game.

**"Finish testing"** returns the game to draft and restores the original start time.

> **Careful:** finishing a test **deletes every passing and log entry** for that
> game. That is the point of it — clearing away the test before the real thing. Do
> not use it on a game that has genuinely been played.

If testing will not start, you are told why — most often an incomplete translation.

### Watching a game

From the games list, on your own game:

| Link | What it shows |
|---|---|
| (statistics) | Every team: which task, and how long they have been on it |
| (live feed) | Every code entered across the game, as it happens |
| (answer log) | The full log across all teams and tasks |

The statistics page is your main screen during a game, and it is also where you
intervene.

### Intervening in a running game

From your game's statistics page:

**Pause / Resume.** Pausing stops every team's hint timer and refuses codes. When
you resume, each team gets back exactly the time it had left. Use it for storms,
incidents, closed streets.

**Move a team to another task.** For a team stuck on a task that has broken — a code
that does not work, a location that is not reachable. The hint timer on the new task
starts fresh, and codes entered for the old one are cleared.

**Return a team to the game.** Undoes "Leave the race" when a captain hit it by
mistake. The hint timer starts fresh.

**Reset the countdown.** Zeroes the time on the current task, if hints have fired at
the wrong moment.

All of this works while the game is running, including while it is paused. Answer
logs are never altered by an intervention — they stay an honest record of what the
team actually typed.

### Ending a game

**"END THE GAME"** ends it for every team at once.

**This cannot be undone.** Teams will no longer be able to enter codes. Use it when
the game is genuinely over.

### Deleting a game

A game can only be deleted **if nobody has played it**. Once a single passing
exists, deletion is refused — it would leave teams' logs and results pointing at
nothing.

For a game that has been played, there is withdrawal instead — ask an administrator.

---

## For administrators

A server administrator (superadmin) is responsible for every game, not only their
own.

The role is granted by another administrator. The very first administrator is
appointed from the server console, because otherwise there would be nobody to grant
it.

### Where things are

Once you have the role, an **"Administration"** section appears in the left menu:

| Item | Address | What it holds |
|---|---|---|
| Overview | `/admin` | Games by status, totals for players/teams/games, applications |
| All games | `/admin/games` | Every game on the server, with actions |
| Players | `/admin/users` | Everyone registered |
| Action log | `/admin/audit` | Who did what |

### Other players' privileges

On a player's page (`/admin/users/NUMBER`) there are "Make administrator" and
"Revoke administrator rights" buttons.

Two limits, neither of which can be lifted:

- **you cannot revoke your own rights** — this prevents accidental lockout and
  guarantees that every demotion has a second party recorded in the log;
- **the last administrator cannot be demoted** — the server must never be left
  without one. This rule holds in the console too.

A player's page shows their contact details — phone, Jabber, ICQ, date of birth.
They are deliberately absent from the list: reading someone's contacts takes a
deliberate click through to their page.

### Actions on games

On `/admin/games`:

**Withdraw / Publish.** Removes a game from the public listings and closes it to
outsiders. The author and administrators can still see it.

> Teams **already playing** carry on playing — withdrawing a game does not strand
> people mid-race in the middle of a city. That behaviour is deliberate.

**Lock / Unlock (editing).** The author can no longer edit the game, start or
finish testing, delete it, or end it. Use it when you need to look into something
and hold the state still.

A freeze does not stop the author **viewing** their game and its logs — only
changing them. It does not restrict administrators at all.

**Delete.** Same rule as for authors: only if the game has never been played. For
anything else, withdraw it.

### Intervening in other people's games

Everything in [Intervening in a running game](#intervening-in-a-running-game) is
available to an administrator in **any** game, not just their own: pause, move a
team, reinstate a team, reset a countdown.

This is what the role is for. The author may be unreachable while a team is standing
in the middle of a city.

### The action log

`/admin/audit` — who, what, when, and to which game.

**What is recorded:** an administrator's actions in **someone else's** game, plus
every grant and revocation of the role.

**What is not:**

- an author's actions in **their own** game. That is ordinary work, not
  administration; recording it would bury the administrative entries in routine;
- reads. The log answers "who changed this", not "who looked at this" — it does not
  record viewing a player's contact details either;
- the appointment of the very first administrator from the console. This cannot be
  worked around: the log is written by the web application, and the console goes
  around it.

Log entries **cannot be edited or deleted** — not through the interface, not by any
other route. A log that its own subject can edit is not a log.

A game's title or a player's nickname is stored in the log **as it was at the time**.
So the entry for a deleted game still names it, rather than showing a number that no
longer leads anywhere.

---

## When something goes wrong

| Symptom | What it means |
|---|---|
| "The organiser has paused the game" | A pause. Wait — no hints are coming and no time is being lost |
| The play page will not open before the start | The game has not started yet; this is normal |
| A team quit by mistake | The game's author or an administrator can reinstate it |
| Testing will not start | Most likely an incomplete translation — the reason is shown |
| A game will not delete | It has been played. Withdraw it instead |
| An author cannot edit their game | Either it has already started, or editing has been frozen by an administrator |
