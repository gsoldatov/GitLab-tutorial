# Overview

This scenario tests the work of deployment pipeline job.

The job runs on main branch together or after migration job and deploys a specified `$TARGET_REF` to a container with a specified color.

# Workflow

The `deploy` job exists only in a production run: create the pipeline with `Run pipeline` on
`main` and the pipeline variable `PRODUCTION_JOBS` - `deploy` alone, or `migrate,deploy`
together. Creating the pipeline runs the jobs - there is no play step. With `migrate,deploy`
the migration stage runs first and `deploy` follows once it succeeds; with `deploy` alone,
`deploy` starts on its own. Set the job's own variables in the same form.

`NGINX_PORT` variable may be optionally set in each step of this scenario 
to override the default Nginx port value `8080`, if that port is in use.

1. Run the initial deployment, together with DB migrations from GitLab's UI as Owner. The following variables should be set:
    - `PRODUCTION_JOBS=migrate,deploy`
    - `DEPLOY_COLOR=blue`
    - `DIRECTION=upgrade`, `REVISION=head`
    - `TARGET_REF=` (empty; the pipeline's commit - note its SHA for step 3)

2. Add a new version to main branch and switch deployment to it:

    2.1. Make and complete a merge request of `valid-feature` (see [valid-merge-request.md](valid-merge-request.md) for details).

    2.2. Run migration and deployment jobs from the GitLab's UI with the following variables
        - `PRODUCTION_JOBS=migrate,deploy`
        - `DEPLOY_COLOR=green`
        - `DIRECTION=upgrade`, `REVISION=head`
        - `TARGET_REF=` (empty; the new merge commit)

3. Rollback deployment to the first version, using the following variables (note that migration rollback is not needed, since new commit didn't modify existing tables):
    - `PRODUCTION_JOBS=deploy`
    - `DEPLOY_COLOR=blue` (the colour that is not live)
    - `TARGET_REF=<the commit deployed in step 1>`

4. Try upgrading to a non-existing commit (job should fail)
    - `PRODUCTION_JOBS=deploy`
    - `DEPLOY_COLOR=green`
    - `TARGET_REF=deadbeefcafe`

5. Try deploying to the same color (job should fail)
    - `PRODUCTION_JOBS=deploy`, `DEPLOY_COLOR=blue` (the live colour), `TARGET_REF=` (empty)

6. Try running a migrate job on main branch as Developer (pipeline should fail to start)
    - `PRODUCTION_JOBS=deploy` (any production run is refused); the developer cannot create a pipeline on protected `main`, so the run is refused before any job exists.

# Commands for Checking Deployment State

The production stack is the `tutorial-prod` compose project. `-a` lists the stopped colour
too - only one colour runs at a time.

```sh
docker ps -a --filter label=com.docker.compose.project=tutorial-prod \
  --format '{{.Names}}\t{{.Status}}'
```

Which colour nginx serves (the rendered conf is the source of truth for the live colour):

```sh
grep 'server app-' temp/deployment/nginx/default.conf
```

The API through nginx. `POST /items` exists only in the `valid-feature` version, so its `405`
is the clearest signal that the first version is live again in step 3:

```sh
curl -sS localhost:8080/health

# 201 with the created user; 409 if that username/email already exists
curl -sS -X POST localhost:8080/users -H 'Content-Type: application/json' \
  -d '{"username":"alice","email":"alice@example.com"}'

# 201 on the valid-feature version; 404 while the first version is live
curl -sS -X POST localhost:8080/items -H 'Content-Type: application/json' \
  -d '{"name":"widget","description":"first"}'
```

Expected after each step:

| Step | live colour | `POST /users` | `POST /items` |
| --- | --- | --- | --- |
| 1 | blue | 201 | 404 |
| 2.2 | green | 201 | 201 |
| 3 | blue | 201 | 404 |
| 4, 5 | unchanged - the job fails before switching | | |