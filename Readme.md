TODO complete the file after project is finished


# Setup Locally

```bash
# Create GitLab config
cp gitlab/.env.example gitlab/.env

# Setup and configure GitLab and a containerized runner
# Script is idempotent and can be called again to update GL's configuration.
./gitlab/setup_gitlab.sh

# Register the API project in GitLab and create its copy in temp dir,
# which can be used for testing the GL setup.
# Calling the script again will reset both GL and temp dir repo copy.
./gitlab/setup_project.sh
```

TODO
- scenario runs
- setup reset
- project teardown

# API Project Local Commands

```bash
# Start the dev database (reads project/.env)
docker compose -f project/docker-compose.dev.yml up -d db

# Stop the dev database, keeping its data volume
docker compose -f project/docker-compose.dev.yml down

# Stop the dev database and delete its data volume
docker compose -f project/docker-compose.dev.yml down -v

# Run the test suite (the dev database must be running; reads project/.env)
cd project && uv run pytest
```

# Other Commands
```bash
# Stop GitLab & its runner
docker compose -f gitlab/docker-compose.yml --env-file gitlab/.env -p gitlab-tutorial down
```

# `temp/` Directory Structure

All files created during GitLab setup and scenario runs are stored here. A `->` marks where a directory is mounted inside a container.

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
└── deployment/              #   -> job containers, at this same absolute path
    └── nginx/               #   -> job containers, via the mount above: Nginx deployment configuration is placed here
```
