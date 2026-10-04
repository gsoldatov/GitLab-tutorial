# Overview

A tutorial project focused on setting up and configuring a containerized GitLab deployment
and using it to automate CI/CD of a Python API project.

All project components are run via Docker on a single machine, to keep things simple.
The components, themselves, are:
- GitLab instance;
- GitLab Runner;
- GitLab Runner executor containers, which are spinned up by Runner via Docker outside of Docker;
- Python API project dev env database (for running tests locally);
- Python API blue / green "production" deployment:
    - Nginx reverse proxy;
    - blue / green API containers;
    - database.

GitLab is configured to have the following users:
- Admin (used for running setup scripts);
- Owner (maintainer of the Python API project);
- Developer (developer, who creates merge requests in the Python API project).

Python API project, managed by GitLab, is located in `project` dir (and is, de-facto, a part of this project).
Its stack includes:
- Python 3.14;
- uv;
- FastAPI;
- PostgreSQL + SQLAlchemy + Alembic;
- pytest.

# Project Structure
- `gitlab/`: GitLab's configuration scripts, templates, .env and Docker Compose files;
- `project/`: Python API project source code, tests, .env and Docker Compose files;
- `scenarios/`: instructions on how to run manual tests of CI pipeline;
- `temp/`: gitignored directory that container various container mountpoints
and files / subdirectories used when running the project setup.


## Temp Directory Structure

NOTE: the tree listed below was used when GitLab's & GitLab Runner's directories were mounted on host.
This setup showed to have some issues, related to changing ownership of the directories from within the containers.
As a result, GitLab & Runner now uses named volumes & binds config files directly.
`temp/gitlab/opt/` and `temp/gitlab/runner/` are no longer in use. 
`temp/gitlab/` structure may be simplified in the future.

```
temp/
├── gitlab/                  # GitLab's own state
│   ├── etc/                 #   -> /etc/gitlab: the rendered gitlab.rb, plus the secrets GitLab generates
│   ├── opt/                 #   -> /var/opt/gitlab: PostgreSQL, Gitaly and the repositories
│   ├── log/                 #   -> /var/log/gitlab: one log directory per omnibus service
│   ├── runner/              #   -> /etc/gitlab-runner: config.toml, rendered, with the token read from the env
│   └── rendered/            #   host-side staging for the rendered templates, plus the hash of the one applied
├── gitlab_credentials/      # admin, owner and developer PATs, plus the runner's glrt- token, mode 0600
├── repo_copies/
│   └── dev/                 # the developer's clone of the GitLab project: branches for a scenario are pushed from here
├── cache/                   # directory mounted in job containers, which contains various caches used by CI jobs (uv, Ruff, MyPy)
└── deployment/              #   -> job containers, at this same absolute path
    └── nginx/               #   -> job containers, via the mount above: Nginx deployment configuration is placed here
```

# Work with Project

## Setup

```bash
# Pull additional branches to local repo
# (they will be used in test scenarios)
for branch in $(git branch -r | grep -v '\->'); do
    git branch --track "${branch#origin/}" "$branch"
done

# Create GitLab config
cp gitlab/.env.example gitlab/.env

# Setup and configure GitLab and a containerized runner
# Script is idempotent and can be called again to update GL's configuration.
./gitlab/setup_gitlab.sh

# Create project dev & prod configs
# (or skip to let `setup_project.sh` create configs with default values)
cp project/.env.example project/.env
cp project/.env.example project/production.env

# Register the API project in GitLab and create its copy in temp dir,
# which can be used for testing the GL setup.
./gitlab/setup_project.sh
```

If a project is run inside a VM, `GITLAB_EXTERNAL_HOST` in `gitlab/.env` may be set
to allow browsing GitLab UI outside of the VM.

## Test Scenarios

`scenarios/` directory contains several scenarios for testing API project's CI pipeline.
See [scenarios readme](scenarios/Readme.md) for details on how to run them.

# Additional Commands

## GitLab Configuration Update

```bash
# If GitLab's configuration updated, it can be propagated to existing deployment
# via the same setup script.
./gitlab/setup_gitlab.sh
```

## Project Reset

```bash
# Reset the project in GitLab and temp dir to its default (remove any made commits to main
# branch, etc.), tear down the production deployment, and delete the images built for it.
./gitlab/setup_project.sh
```

## Teardown

```bash
# Remove all project containers, volumes, built API images and temp files
./gitlab/cleanup.sh
```

## API Project Local Commands

Note: `project/.env` is expected before running these commands.

`uv` commands must be invoked from `project/` directory.

```bash
# Setup dependencies & venv
uv sync

# Start the dev database
docker compose -f project/docker-compose.dev.yml up -d db

# Configure dev database & run migrations
uv run python src/db/scripts/app_db.py
uv run alembic -c src/db/alembic/alembic.ini upgrade head

# Stop the dev database and delete its data volume
docker compose -f project/docker-compose.dev.yml down -v

# Run linter and type checker
uv run ruff check src
uv run ruff format --check src
uv run mypy

# Run the test suite (the dev database must be running; reads project/.env)
uv run pytest
```
