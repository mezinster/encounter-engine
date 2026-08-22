# Performance testing

Whether the site will survive your next game night, and how we find out before it matters.

Installation: [deployment.en.md](deployment.en.md). User manual: [en.md](en.md).
Русская версия: [performance.ru.md](performance.ru.md).

---

## The problem in one paragraph

An encounter game does something unusual to a website. For most of the evening almost nothing
happens — teams are walking around a city, looking at buildings, arguing about a riddle. Then, all
at once, everybody does the same thing at the same second: at the start, everyone logs in; at each
new level, everyone types a code. The server is idle, idle, idle, and then very busy for ten
seconds.

That shape is what breaks things. A server that comfortably handles two hundred people *browsing*
can fall over when forty of them press a button together.

So "will it cope?" is not one question. It is three.

---

## The three questions

### 1. `ramp` — how many teams can be playing at once?

**Picture a shop filling up through the morning.** Customers arrive a few at a time. You add ten,
then twenty, then forty, and watch: are people still being served quickly, or is there a queue at
the till?

This measures **how much steady custom the shop can hold**. It is the gentle question, and it
usually gives a reassuring answer, because people arriving gradually are easy to absorb.

### 2. `stampede` — what happens when everybody arrives at once?

**Now picture the same shop on the first morning of a sale.** The doors open and two hundred people
come through in thirty seconds. Nobody is browsing yet. They are all at the door, all at the same
moment.

This is what a game night actually does. Everyone logs in at the whistle.

**And logging in is the expensive part.** Checking a password is deliberately slow — the site does a
lot of arithmetic on purpose, so that somebody who steals the database still cannot guess anyone's
password. That is the right trade for security, but it means every single login costs real work
that cannot be sped up, cached, or skipped. A hundred of them landing together is a hundred times
that work, on one small server, in one moment.

**This is the question that decides whether your game night works**, and it is the one a gentle test
will never ask.

### 3. `hold` — does it get tired?

**Picture keeping the shop full all afternoon**, not just for a few minutes.

Our server is a small, inexpensive kind that works rather like an electric scooter. While it is
parked it charges up a reserve. When you need speed it spends that reserve and goes fast. But the
reserve is finite: run hard for long enough and it empties, and then you are pedalling.

This matters enormously, because **a short test flatters the server.** Five minutes of load runs
entirely on the reserve and looks wonderful. Hour two of a real game is a different machine.

So `hold` keeps the pressure on long enough for the reserve to run out, and measures what is left.
That is the number that predicts the second half of an evening.

---

## What we actually found

We ran the first two of these against the live site in August 2026. Same server, same game, the
same 120 teams both times.

| how the teams arrived | how long a page took |
|---|---|
| spread over 22 minutes | **0.2 seconds** |
| all within 30 seconds | **5.9 seconds** |

Nothing broke in either test. Nobody got an error. The second one simply became *thirty times
slower* — the difference between a page appearing instantly and a page you would assume was frozen.

The only thing that changed was how quickly people arrived.

This is exactly why the gentle test on its own is misleading. It said "the server is barely
working, we have plenty of room." That was true, and it was an answer to a question a real game
night never asks.

---

## What a test does to the real site

It is worth knowing, because these tests run against the **live** site.

To measure anything we first create a temporary crowd: a few hundred pretend players, on a copy of
one of your games, marked so nobody real can join it. They log in and submit codes like real teams
would. Then they are deleted — every account, every team, every log line.

Three things keep this safe:

- **The pretend players cannot receive email.** Their addresses use a reserved ending that does not
  exist anywhere on the internet, so even if something tried to write to them, there is nowhere for
  it to go.
- **The test stops itself.** If pages start taking longer than two seconds, it gives up
  immediately rather than pushing further. The server is shared with a few other small services,
  and none of them signed up for this.
- **Cleaning up is not optional.** It happens whether the test succeeded, failed, or was cancelled
  halfway. If it ever cannot finish, it says so loudly rather than quietly leaving hundreds of fake
  accounts behind.

The cleanup is the part to care about. Everything else is measurement; that part is housekeeping in
someone's real database.

---

## Where the answers live

Every run leaves a small file in [`docs/perf/results/`](../perf/README.md).

It records not just the number but **everything that could explain it**: which server size, which
game, how many teams, which of the three questions, how full the reserve was, and how far away the
machine doing the measuring was. Without all of that, two numbers a year apart cannot be compared —
you would have no way of knowing whether the difference came from the server, the game, a code
change, or simply the time of day.

That is the whole reason the files exist. A number on its own does not survive contact with next
year.
