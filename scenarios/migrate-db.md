# Overview

This scenario tests the work of the database migration pipeline job.

The job ensures that production db container is up and then runs a one-shot container,
which applies a specific Alembic revision in a specific direction,
using a specific commit of the repo.

# Workflow

Each step runs the `migrate` job, which exists only in a production run: create the pipeline
with `Run pipeline` on `main` and the pipeline variable `PRODUCTION_JOBS=migrate`. Set the
other variables in the same form; on its own the job defaults to `DIRECTION=upgrade`,
`REVISION=head` and `TARGET_REF` empty (the pipeline's commit).

1. Run a migrate job on main branch from GitLab's UI as Owner. The following variables should be set:
    - `PRODUCTION_JOBS=migrate`
    - `DIRECTION=upgrade`, `REVISION=head`, `TARGET_REF=` (empty)

2. Add a second revision to main branch and run its migrations:

    2.1. Make and complete a merge request of `valid-feature` (see [valid-merge-request.md](valid-merge-request.md) for details).

    2.2. Run migration job from the GitLab's UI with the following variables
        - `PRODUCTION_JOBS=migrate`
        - `DIRECTION=upgrade`, `REVISION=head`, `TARGET_REF=` (empty)

3. Downgrade to the first revision, using the following variables:
    - `PRODUCTION_JOBS=migrate`
    - `DIRECTION=downgrade`, `REVISION=a3f1c2d4e5b6`, `TARGET_REF=` (empty)

4. Try upgrading to a non-existing revision (job should fail)
    - `PRODUCTION_JOBS=migrate`
    - `DIRECTION=upgrade`, `REVISION=deadbeefcafe`, `TARGET_REF=` (empty)

5. Try running a migrate job on main branch as Developer (pipeline should fail to start)
    - `PRODUCTION_JOBS=migrate`; the developer cannot create a pipeline on protected `main`, so the run is refused before any job exists.

# Commands for Checking DB State

The production database is the `db` service of the pinned `tutorial-prod` project, so its
container is `tutorial-prod-db-1`. Connect to the app database as `app_user`: the image
trusts the local socket, so no password is needed. (`docker compose exec` works too, but the
compose CLI needs `APP_IMAGE` and `DEPLOY_DIR`, which only the jobs export.)

List the tables:

```sh
docker exec tutorial-prod-db-1 psql -U app_user -d tutorial -c '\dt'
```

Check whether each table exists (`NULL` = absent) and the applied revision:

```sh
docker exec tutorial-prod-db-1 psql -U app_user -d tutorial \
  -c "SELECT to_regclass('public.users') AS users, to_regclass('public.items') AS items;" \
  -c 'SELECT version_num FROM alembic_version;'
```

Expected state after each workflow step:

| Step | `users` | `items` | `version_num` |
| --- | --- | --- | --- |
| 1 | present | `NULL` | `a3f1c2d4e5b6` |
| 2.2 | present | present | `b7d41e9a2c63` |
| 3 | present | `NULL` | `a3f1c2d4e5b6` |
| 4, 5 | unchanged - the job fails before touching the database | | |