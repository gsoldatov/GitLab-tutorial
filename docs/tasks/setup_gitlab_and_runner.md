# Setup: GitLab instance & containerized runner

**Status:** done. Ran against a real instance: `gitlab/setup.sh` brought GitLab and
the runner up, `gitlab/smoke-test.sh` ran a pipeline whose jobs reached the host's
Docker daemon, and both scripts were re-run to confirm they are idempotent.

Goal: `gitlab/` scripts and artifacts that bring up a self-hosted GitLab CE in
Docker and register an instance-scoped, containerized runner (Docker executor)
that reaches the host's daemon over DooD.

Not in scope for this task: `project/` app and tests, the real `.gitlab-ci.yml`,
`docker-compose.prod.yml`, nginx, blue/green deploy, migration jobs, branch
protection, group creation, the reset script, and the deferred SAST / versioning
/ cleanup items.

## Deliverables

| Path | What it is | State |
| --- | --- | --- |
| `gitlab/.env.example` | Every knob, documented, shell-sourceable and Compose-readable | done |
| `gitlab/docker-compose.yml` | GitLab + runner in one compose project | done, `compose config` clean |
| `gitlab/templates/gitlab.rb.tmpl` | Omnibus configuration | done |
| `gitlab/templates/runner-config.toml.tmpl` | Runner `config.toml`, token-free | done |
| `gitlab/lib/common.sh` | Paths, logging, env load/validate, render, deliver, compose/API/Rails wrappers, readiness wait | done, exercised by a real run |
| `gitlab/setup.sh` | Eight phases, idempotent, `--force-pat`, `--skip-wait`, `--help` | done, ran twice, `exit=0` |
| `gitlab/smoke-test.sh` | Throwaway pipeline proving jobs reach the host daemon | done, pipeline green, project cleaned up |

Generated, all under the already-gitignored `temp/`:

```
temp/gitlab/etc/          -> /etc/gitlab           (rendered gitlab.rb, secrets, host keys)
temp/gitlab/opt/          -> /var/opt/gitlab       (database, gitaly, repositories)
temp/gitlab/log/          -> /var/log/gitlab
temp/gitlab/runner/       -> /etc/gitlab-runner    (rendered config.toml, token-free)
temp/gitlab/rendered/                              (our rendered sources, user-owned)
temp/gitlab_credentials/                           (admin/owner/developer PATs, runner.env)
temp/deploy/                                       (pre-created so the daemon never makes it root-owned)
```

## Decisions

**1. DooD with the existing user. No extra host user, no rootless daemon.**
GitLab's own documentation states that adding a user to the `docker` group grants
it full root, so the original "additional user in the docker group" idea was a
privilege *expansion*, not a reduction. A genuine rootless daemon would
additionally need a subuid/subgid range for a new user and a fix for
`kernel.apparmor_restrict_unprivileged_userns=1`, which is active on this host.

**2. `external_url` is the docker0 bridge gateway (`172.17.0.1`), auto-detected.**
It is the single address reachable by all four consumers: the host shell, the
host browser, the runner container (routing to the host) and the job containers
(whose gateway it is). It is independent of DHCP and of the VM's networking — the
only outward address here is `10.0.2.15` over VirtualBox NAT, with no bridged or
host-only adapter, so a LAN address would not be reachable from outside anyway.
`GITLAB_EXTERNAL_HOST` overrides it. This also avoids depending on
`host-gateway`, which is unconfirmed in GitLab's docs, and needs no `/etc/hosts`
edit.

**3. Job containers stay on the default bridge.**
Deliberately no `network_mode`. Joining the GitLab compose network would let each
job's `services:` containers collide on the shared `postgres` DNS alias across
concurrent jobs. Reaching GitLab at its published address needs no
`extra_hosts` at all.

**4. One compose project for GitLab and its runner.**
The runner gets service-name DNS for free, and its registration lives in the
rendered `config.toml` rather than in an interactive `register` step, so a
re-`up` re-registers itself harmlessly.

**5. The runner token never appears in the rendered config.**
`token = "${RUNNER_TOKEN}"`, with the value supplied by a compose `env_file`
pointing at `temp/gitlab_credentials/runner.env`. Verified that the long form with
`required: false` works and that an absent file is skipped without error, which is
what lets an early `up -d gitlab` succeed before setup has registered anything.

**6. GitLab state lives under `temp/gitlab/`, credentials under `temp/gitlab_credentials/`.**
A deliberate deviation from two things AGENTS.md currently claims: that PATs are
written back into `gitlab/.env`, and that everything in `temp/` is disposable.
The consequence to remember: those bind directories end up owned by root and uid
999, so `rm -rf temp/` is **not** a safe cleanup — it destroys
`gitlab-secrets.json` and the database. `deliver_file` therefore writes directly
when the path is still writable and through a one-shot container when it is not,
so re-rendering works either way.

**7. Accounts.** Root is renamed to `GITLAB_ADMIN_USERNAME`; its password comes
from `gitlab_rails['initial_root_password']` in `.env`, never from an API password
update, because an API-driven change forces a change-on-next-login. Owner and
developer are created with `skip_confirmation=true` since there is no SMTP. The
admin **email is deliberately never touched**: changing an address marks it
unconfirmed and nothing can confirm it here, which would lock the account out of
the web UI.

**8. `setup.sh` runs no privileged commands.** The only privileged work involved
is GitLab's own sysctl set, which setup detects and prints rather than applies.
This corrects an earlier claim of mine: `vm.overcommit_memory` and
`fs.inotify.max_user_watches` are *not* GitLab-documented tunings. The real
mechanism is that the omnibus container writes its own values to
`/opt/gitlab/embedded/etc/90-omnibus-gitlab.conf`, which the host may need to
mirror.

**9. The first admin PAT is minted inside the container.** There is no API route
to it: creating a token requires a token. `bootstrap_admin_token` uses
`gitlab-rails runner` exactly once, then everything else goes through the v4 API.

**10. Tuning follows GitLab's memory-constrained guidance**, with the documented
key names only: `puma['worker_processes'] = 0`, `sidekiq['concurrency'] = 10`,
monitoring and exporters off, `registry['enable'] = false`. This corrects two
invented keys from an earlier draft (`sidekiq['max_concurrency']` and
`postgresql['shared_buffers']`).

**11. `monitoring_whitelist` is widened to `172.16.0.0/12`.** `/-/readiness` is
unauthenticated but allowlisted, and traffic arriving through a published port is
SNAT'd to the bridge gateway rather than looking like `127.0.0.1`, so without this
the host-side readiness wait is refused and every run looks like a failure.

**12. Reconfigure is driven by a content hash.** `setup.sh` compares the freshly
rendered `gitlab.rb` against `.gitlab.rb.applied`, which is written only after a
readiness wait succeeds — so an unrelated re-run does not restart GitLab, and a
failed configure is retried rather than recorded as done.

**13. A runner whose token we no longer hold is replaced, not reused.** GitLab
cannot return a token twice, so delete-and-recreate is the only idempotent path.

**14. Pins**, each verified with `docker manifest inspect` on 2026-09-23:
`gitlab/gitlab-ce:19.4.1-ce.0` (the CE image requires the `-ce.0` suffix; a bare
`19.4.0` does not exist), `gitlab/gitlab-runner:alpine-v19.4.0` (the runner has no
19.4.1 release at all, so the families differ — that is normal), and
`docker:24.0.5-cli` for job images.

**15. Layout:** `setup.sh` + `lib/common.sh` + `templates/`, so the reset script
in a later task can reuse the shared helpers instead of duplicating them.

## Completed and verified

Before the run:

- Pinned tags confirmed to exist; the newest CE patch was found by listing tags,
  not assumed.
- `docker compose config` resolves cleanly: `8929:8929`, `2222:22`, all three
  binds to absolute repo paths, network `gitlab-tutorial_default`, image tags
  interpolating from `.env`.
- `env_file` behaviour tested in isolation: long form + `required: false` works
  for both a present and an absent file.
- `bash -n` clean on `common.sh` and `setup.sh`.
- `validate_env` passes against `.env.example`; both templates render; the rendered
  runner config parses as valid TOML with `url = http://172.17.0.1:8929`, `token`
  left unexpanded, and the identical-path `temp/deploy` mount present.
- The placeholder-drift guard fires correctly, and `deliver_file`'s direct-write
  path writes matching contents.

By the run:

- First boot: image pulled, reconfigure finished, `/-/readiness` went green after
  540s, and the admin PAT was minted through `gitlab-rails runner` and accepted by
  `GET /user`. No scope fallback was needed, so `create_runner` is valid here.
- Accounts: root renamed, owner and developer created with `skip_confirmation` and
  each given a PAT.
- Runner: registered over the API, container started, **online after 6s**.
- Re-running `setup.sh`: no GitLab restart (`gitlab.rb` hash unchanged, `ready after
  0s`), PATs reused, accounts found, runner reused, `exit=0`.
- `smoke-test.sh`: CI file linted by GitLab (`valid`), pipeline green in 17s, both
  jobs `success`, project deleted. The trace shows the job seeing the host's
  `gitlab-tutorial-gitlab-1` and `gitlab-tutorial-gitlab-runner-1` containers and
  `daemon: name=ubuntu-dev server=29.6.0` — DooD proven, not inferred.
- Re-running `smoke-test.sh` on the same fixed name works, on every exit path.

## Corrected by the run

- **`admin` is a reserved username.** The shipped default was rejected by
  `PUT /users/1` with `{"username":["admin is a reserved name"]}`, so the example
  now uses `tutorial-admin`, and `validate_env` rejects GitLab's reserved top-level
  paths before anything starts.
- **A file write returns `{file_path, branch}` only** — no commit id — so the smoke
  test reads the branch's newest commit to name the pipeline.
- **Deleting a project is two calls.** Marking it for deletion renames the path to
  `<path>-deletion_scheduled-<id>` (which is what frees the name), and only then
  does `permanently_remove=true&full_path=<renamed>` purge it; the original
  assumption that one call with the original path would do both was wrong.
- **The job image already has Compose**: `docker compose version` in a job prints
  `Docker Compose version v2.21.0`. No helper container or plugin install is needed
  for the deploy task.
- **`check_ports_available` killed the script silently.** `port_in_use "$port" &&
  die` returned non-zero for a *free* port, and as the last command of the loop that
  became the function's status, which `set -e` acted on with no message. It is an
  `if` now. Every other `A || die` / `A && B` in both scripts is the last statement
  of nothing, so this was the only instance.
- The container's `(healthy)` is meaningless: its healthcheck self-skips
  (`gitlab-healthcheck-rc not found`) and exits 0.

## Notes for whatever comes next

- GitLab CE cost about 6 GB of disk (17 GB → 11 GB free), which is why preflight's
  20 GB warning fires on this machine.
- The first reconfigure took ~9 minutes here; a warm one is instant.
- `ci_config_path` writability is still unverified, and only the project task needs
  it.

## How to run

```sh
gitlab/setup.sh          # first run creates gitlab/.env from the example and exits
gitlab/setup.sh          # brings it up, registers the runner
gitlab/smoke-test.sh     # proves jobs reach the host daemon
```
