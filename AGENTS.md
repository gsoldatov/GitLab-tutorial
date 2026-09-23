# GitLab CI/CD Tutorial

## Purpose

A tutorial repo that stands up a self-hosted GitLab in Docker, an instance-scoped
runner, and a small FastAPI + PostgreSQL service — then demonstrates a real
pipeline against them: lint, type checks and tests on merge requests, blue/green
deployment to a simulated production, and DB migrations.

## Status

Docs only. `project/` and `gitlab/` do not exist yet — everything below describes
the intended design, not current code.

## Repository layout

- `gitlab/`:
  - GitLab configuration (`.env.example`);
  - setup, reset & other scripts;
  - file templates added to GL;
  - other utilities for managing GL instance and running scenarios;
- `project/` — the application, pushed to GitLab as its own project: source, tests, `Dockerfile`, `docker-compose.prod.yml`, nginx conf template, `.gitlab-ci.yml`, `.env.example`.
- `temp/` — gitignored directory for :
  - `dev/` (developer's repo clone);
  - `deploy/` (rendered nginx conf);
  - mounted directories & anything else disposable;
- `docs/` — `to-do.md` is the task list; `plan-suggestions.md` is a non-authoritative reference of possible approaches, **not** a plan.

## Architectural decisions

### Runner and host integration

- One runner, **instance-scoped**, Docker executor. Registered once, so it survives
  project deletion and reset can freely recreate the project.
- The runner mounts `/var/run/docker.sock` and the repo's `temp/deploy` at
  **identical absolute paths**.
- DooD is a deliberate, documented anti-pattern: Docker here is rootful, so every job
  gets host root. Volume mounts are per-runner, not per-job, so lint and test jobs
  inherit it too. Do not "fix" this without revisiting the whole deploy design.
- `gitlab.rb` and the runner's `config.toml` are rendered from `gitlab/.env` by setup,
  never hand-edited;
- Ports in use: 22 (host SSH) and 53 (resolved). Chosen: GitLab HTTP 8929, GitLab SSH
  2222 (paired with `gitlab_shell_ssh_port`), nginx 8080.


### Path semantics (why the deploy dir exists)

- `docker build` and compose `build:` stream the build context over the socket, so
  they read paths inside the **job container**.
- Compose **bind mounts** are resolved to absolute paths by the client and then read
  by the daemon on the **host**. When those two differ you silently get an empty
  directory or a permission error. So the prod compose file has exactly one bind
  mount, sourced from `${DEPLOY_DIR}` (`<repo>/temp/deploy`), which exists identically
  on both sides.
- `db` uses a **named volume** — daemon-side, immune to the above.

### CI configuration

- Single file `project/.gitlab-ci.yml`, no `include`s. Setup points the project's
  CI/CD configuration file path at it (verify REST writability; UI as fallback).
  Until it is set, the project has no pipeline at all.
- `rules: changes` and `cache: key: files` are repo-root-relative, so they carry a
  `project/` prefix. Commands run via `cd project` in `before_script`; `after_script`
  starts fresh at `$CI_PROJECT_DIR`.
- Stages: lint, test, build, migrate, deploy. MR pipelines run lint/test/build; main
  runs those plus automatic `upgrade head` and a manual deploy.
- `resource_group` on migrate and deploy, otherwise two pipelines race the same nginx
  switch and the same Alembic head.
- No GitLab environments. Deploy state is the nginx conf.

### Images — no container registry

- The build job builds on the host daemon over the socket and tags
  `gitlab-tutorial-api:$CI_COMMIT_SHA`. No registry means no registry config and no host
  daemon config changes.
- Consequence: build and deploy must share one daemon, and only SHAs whose image
  still exists locally can be deployed. Pruning must spare `gitlab-tutorial-api:*`.
- Build runs on MRs too — it is the only thing that validates the Dockerfile, and the
  shared daemon layer cache makes it cheap.
- The deploy job exports `APP_IMAGE` into the compose invocation's environment. No
  generated `.env` file.

### Production stack and blue/green

- `docker compose -p tutorial-prod` with `nginx` (publishes 8080), `app-blue`,
  `app-green`, `db` (named volume), and a one-shot `migrate`.
- App containers publish no host ports; nginx addresses them by service name.
- Deploy is a manual job on main with runtime variables `DEPLOY_SHA` and
  `DEPLOY_COLOR`: fail early if image was not built, start the target container, wait
  for `GET /health`, render the nginx conf, `nginx -s reload`, then stop the other
  container.
- The reload matters: nginx resolves upstream names once at startup and keeps the
  stale IP when a container is recreated.
- The nginx conf is the source of truth for which colour is live.

### Migrations

- Run via `docker compose run --rm migrate …` using the **image of the target
  commit** — Alembic scripts ship inside the image, so the revision tree always
  matches the deployed code. Running migrations from a different commit's checkout is
  the trap to avoid.
- Manual jobs: `upgrade <rev>` and `downgrade <rev>`. Downgrade always takes an
  explicit revision (Alembic's `-1` is not idempotent) and is gated to a protected ref.

### Reset

- Delete and recreate the GitLab project, then re-render config, re-push the base
  state, re-apply branch protection and members.
- `docker compose down -v` for production; wipe `temp/` but spare `gitlab-tutorial-api:*`
  images, unless a specific CLI arg is provided for the script;
- Chosen over force-pushing a protected `main` (needs unprotecting and force-push
  toggling via the API) and over hand-cleaning merged MRs (leaves records behind).

### Configuration

- `gitlab/.env.example` → `gitlab/.env` (gitignored, hand-populated): GitLab image
  tag, HTTP and SSH ports, external host, group/project name, owner and developer
  username + password, plus generated PATs written back by setup.
- `project/.env.example` → `project/.env` (gitignored, hand-populated): local-dev DB
  URL and credentials, app flags. **Never read by CI or by containers.**
- Production DB URL, credentials and the nginx port are declared in
  `project/docker-compose.prod.yml`, so a local-dev URL can never reach production.
- No GitLab CI/CD variables in v1. If a real secret appears later, that is the layer
  to use (masked and protected).
- Setup validates required keys and fails loudly when a `.env` is missing or
  incomplete.

### Application

- FastAPI; async SQLAlchemy + asyncpg; sync psycopg for Alembic, whose migration
  context is sync.
- `users` table with create route, one Alembic migration, `GET /health`.
- `pydantic-settings`; environment variables win, `project/.env` is a local
  convenience.
- Tests: per-job `services: postgres:16-alpine`, `DATABASE_URL` set explicitly in the
  job, `httpx.ASGITransport`, per-test transaction rollback.

## Deferred (not v1)

SAST/security scanning, automatic versioning, periodic cleanup jobs, and the scenario
harness. Reserved scenario branches: `valid app update`, `broken app update`,
`new db migration`.


## Open — verify before writing setup scripts

- Whether `ci_config_path` is writable through the REST API on the pinned version.
- How instance-runner authentication tokens are created there. Registration tokens
  are gone, so this may need one manual UI action in setup.
- Whether users can be created without email confirmation.
- GitLab's documented memory minimum for the pinned version, to confirm the tuning
  targets.
- Pin the exact `gitlab-ce` patch — newest stable at implementation time.
