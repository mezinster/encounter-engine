# Running the app as a Portainer stack (or plain docker compose)

`compose.yml` beside this file deploys the whole app on one Docker host: the
web container (the same GHCR image the Kamal production deploy runs), a plain
`postgres:16`, and [Mailpit](https://mailpit.axllent.org/) to catch outgoing
mail. It is written for a homelab — plain HTTP on a LAN, no Azure, no wal-g
backups — and does **not** replace or interact with the Kamal deployment in
`config/deploy.yml`.

## Variables

Set these in Portainer's environment-variables section of the stack (never in
a file committed to git), or in an `.env` file next to the compose file for
plain `docker compose`.

Required:

| Variable | What it is |
|---|---|
| `SECRET_KEY_BASE` | Rails' signing/encryption root. Generate per stack: `openssl rand -hex 64`. Boot refuses to start without it. |
| `POSTGRES_PASSWORD` | Database password. Keep it **alphanumeric** — it is spliced into `DATABASE_URL` and nothing escapes it. |

Optional (defaults in parentheses):

| Variable | What it is |
|---|---|
| `APP_HOST` (`localhost`) | Host used in links inside outgoing letters. Set to the address you browse to, e.g. `192.168.30.32`. |
| `WEB_PORT` (`3000`) | Published app port. |
| `MAILPIT_PORT` (`8025`) | Published Mailpit web UI port — open it in a browser to read every letter the app "sent". |
| `FORCE_SSL` (`false`) | Leave `false` for plain HTTP. Set `true` only when a TLS-terminating proxy fronts the stack — with it on, the session cookie is `Secure` and login breaks over `http://<lan-ip>`. |
| `TZ` (`Europe/Vienna`), `DEFAULT_LOCALE` (`ru`) | Same meaning as in the Kamal deploy. |
| `WEB_IMAGE` (`ghcr.io/mezinster/encounter-engine:latest`) | Override to run a locally built image. |
| `MAIL_FROM` (`encounter@localhost`) | From-address on letters. |

`ANTHROPIC_API_KEY` is deliberately absent: without it the AI translation
feature is entirely off, which is the right state for a homelab. Add it to the
`web` service environment if you want the feature.

## The image is private

`ghcr.io/mezinster/encounter-engine` is a private GHCR package. Two options:

1. **Make the package public** (GitHub → the package → Package settings →
   Change visibility). The repository is already public; the image contains
   nothing the repo doesn't. Then no credential is needed anywhere.
2. **Give Portainer a credential**: a GitHub personal access token with
   `read:packages` scope, added in Portainer under **Registries** (or as a
   registry Source) with URL `ghcr.io` and your GitHub username.

## Deploying from Portainer (App Delivery)

1. **App Delivery → Sources → Add source**: this GitHub repository
   (`https://github.com/mezinster/encounter-engine`), ref `refs/heads/master`.
   Public repo — no auth needed for the source itself.
2. If the image stays private: add the GHCR credential (above) so the
   deployment can pull.
3. **Create the workflow / git-backed stack**: compose path
   `deploy/portainer/compose.yml`, target your local Docker environment, and
   set the two required variables in the environment-variables section.
4. **GitOps updates**: enable polling (or a GitHub webhook) and "re-pull
   image" — pushes that change the compose file redeploy the stack, and new
   CI-built images roll out on the next poll because the tag is `latest`.

Note: in Portainer **Community Edition** a workflow can be created and viewed
but is read-only afterwards; editing GitOps settings post-creation needs
Business Edition (the free 3-node license is enough).

## First boot and day-2 notes

- The entrypoint runs `db:prepare` before Puma binds: first boot creates the
  schema by itself, later boots run pending migrations. Nothing to do by hand.
- The healthcheck hits `/up`; `start_period` is generous because that first
  `db:prepare` happens inside it.
- App data lives in two named volumes: `pgdata` (database) and `storage`
  (uploads). `docker compose down` keeps them; `down -v` destroys the game
  data with them.
- Mail: every letter (signup welcome with the generated password, invitations)
  lands in Mailpit at `http://<host>:8025` and never leaves the machine. Point
  the `SMTP_*` variables at a real relay to send real mail — and only then
  does the choice of `MAIL_FROM` start to matter.
- To put it behind TLS (e.g. Nginx Proxy Manager / Traefik / Caddy on the same
  box): proxy to `web:3000` or the published port, forward
  `X-Forwarded-Proto`, and set `FORCE_SSL=true`.
