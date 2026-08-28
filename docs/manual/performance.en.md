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

### Then we asked how much time the crowd needs

On 27 August 2026 we ran the same 120 teams three more times, changing one thing only: how long
they took to arrive.

| the 120 teams arrived over | how long a page took | did the test survive? |
|---|---|---|
| 30 seconds | **8.0 seconds** | no — stopped early, too slow to continue |
| 60 seconds | **0.31 seconds** | yes, comfortably, for the full run |
| 120 seconds | **0.32 seconds** | yes, comfortably, for the full run |

**Doubling the time the crowd takes to arrive made the site twenty-six times faster.** Nothing else
was different: same server, same game, same number of teams, same day.

And notice the last two rows. Going from one minute to two changed essentially nothing — 0.31 to
0.32 seconds. There was nothing left to fix. **One minute is already enough**, and past that you are
buying something you already have.

That is what a limit looks like from both sides. Below it the server barely notices the crowd.
Above it, work arrives faster than one server can do it, the queue grows, and everybody waits behind
everybody else. Between 30 and 60 seconds this site crosses that line.

### What to do about it, in one sentence

**Give 120 teams about a minute to get in, not thirty seconds.**

In practice that means not sending everyone the same "we start now" message at the same instant.
Announce the start a minute or two ahead, or let teams log in before the whistle rather than at it.
Nothing needs to be bought or rebuilt; the crowd simply needs a door wide enough for the time you
give it.

If your game is much larger than 120 teams, give it proportionally longer — the server's capacity is
roughly *two teams arriving per second*, and that figure is what all of the above amounts to.

### Why logging in is the part that matters

The tests point at one thing. In the healthy runs, nine requests in ten finished in about **0.06
seconds** — and the slowest one in twenty took about **0.31 seconds**, five times longer. That slow
slice is almost exactly the share of requests that are logins.

You can see the password check in the numbers. It costs roughly a quarter of a second of pure
arithmetic, every time, and it cannot be cached or skipped — that is the point of it, as described
above. Everything else the site does is fast. So the question is never "can the server handle 120
teams", it is "how many password checks per second", and the answer on this machine is about two.

### And then we asked whether it gets tired

It does not. On the same day we kept 120 teams playing steadily for **forty minutes** — the test the
electric-scooter passage above was written for.

The reserve barely moved. It began full, dipped by half of one unit out of 288, and was back to full
before the run ended. For most of those forty minutes the server was *charging* rather than
spending: steady play took about a tenth of the machine's power, and the reserve fills whenever the
draw stays under a fifth. Memory sat flat throughout.

**So hour two is not where the risk is. The whistle is.** A long game does not wear this server
down; a crowded start overwhelms it. Everything above about giving the crowd a minute to arrive is
the whole story — and this is the measurement that says no second story is hiding behind it.

One honest footnote, because it is the same lesson a third time. Our own forty-minute test begins by
starting all 120 teams at the same instant, which is a rush sharper than any of the three in the
table above. That opening moment produced every failure the test recorded: 22 login attempts out of
142 did not get through first time. Once everyone was in, nothing failed for forty minutes. **The
test walked into the same door the players do.**

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
