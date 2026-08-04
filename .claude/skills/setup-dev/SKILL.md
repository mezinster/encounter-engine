---
name: setup-dev
description: Bootstrap a local development environment for this Merb app from a fresh clone — submodules, Ruby 2.6.5, gems, and the development database.
disable-model-invocation: true
---

Bring this repository from a fresh clone to a running local server. Work through the steps in
order and stop at the first failure — later steps depend on earlier ones.

## 1. Vendored framework submodules

Merb and merb-auth are vendored, not installed from RubyGems. The app cannot boot without them.

```bash
git submodule update --init --recursive
git submodule status   # both lines must start with a space, not '-'
```

## 2. System build dependencies

Ruby 2.6.5 is compiled from source, so it needs a toolchain. This step requires `sudo` — ask the
user to run it themselves rather than attempting it:

```bash
sudo apt-get update && sudo apt-get install -y \
  build-essential autoconf bison libssl-dev libyaml-dev libreadline-dev \
  zlib1g-dev libncurses5-dev libffi-dev libgdbm-dev libsqlite3-dev \
  libxml2-dev libxslt1-dev
```

`libssl-dev` matters most: Ruby 2.6 builds against OpenSSL 1.1 and **fails** against OpenSSL 3.0.
Check with `openssl version` — on Ubuntu 22.04+ this step needs a separately built OpenSSL 1.1.1.

## 3. Ruby 2.6.5 via rbenv

```bash
git clone --depth 1 https://github.com/rbenv/rbenv.git ~/.rbenv
git clone --depth 1 https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
rbenv install 2.6.5      # compiles from source; takes several minutes
rbenv local 2.6.5        # writes .ruby-version in the repo
```

rbenv is not on PATH in non-login shells here. Prefix commands with the `export PATH=...` line
above, or invoke binaries as `~/.rbenv/shims/<cmd>`.

## 4. Gems

```bash
gem install bundler -v 2.2.3
bundle config set --local without production
bundle install
```

The `production` group holds `pg`, which needs Postgres headers and is not needed locally.
Native extensions that do get built: `sqlite3` (pinned `<1.4`), `nokogiri`, `thin`, `byebug`.

## 5. Database

```bash
cp -n config/database.yml.sample config/database.yml   # only if the file is missing
MERB_ENV=rake bundle exec rake db:migrate
```

`config/database.yml` is gitignored. The committed sample defaults development to MySQL — for a
local sqlite setup point `:development:` at `db/development.sqlite` with `:adapter: sqlite3`.
The test environment already uses in-memory sqlite and needs no setup.

## 6. Verify

```bash
bundle exec spec spec/          # RSpec 1.x specs
bundle exec cucumber            # full feature suite — what CI runs
bundle exec merb                # dev server on http://localhost:4000
```

Report which of these passed and which did not. Do not claim the environment works until the
server has actually booted and at least one suite has run.
