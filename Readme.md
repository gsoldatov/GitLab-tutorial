TODO complete the file after project is finished


# Setup Locally

```bash
# Create GitLab config
cp gitlab/.env.example gitlab/.env

# Setup and configure GitLab and a containerized runner
./gitlab/setup.sh
```

TODO
- project configuration commands
- scenario runs
- setup reset
- project teardown

# Other Commands
```bash
# Stop GitLab & its runner
docker compose -f gitlab/docker-compose.yml --env-file gitlab/.env -p gitlab-tutorial down
```
