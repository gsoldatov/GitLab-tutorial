# Overview

+ setup & configure GitLab in Docker container;
+ setup Python API project with a PostgreSQL db & tests;
+ configure project repo to be managed by GitLab;
- configure jobs for merge request (linting & tests);
- configure jobs for deploying:
    - blue / green deployment (Nginx + 2 API containers + db container) on the same machine (separately from GL container(-s));
    - jobs:
        - build an image for a commit;
        - deploy a commit to blue / green & switch between containers;
        - upgrade / downgrade to a specific db migration;
- use-case scenario harnesses (scripts + manual instructions for adding merge requests, deploying to production, migrating db).

Additional:
    - security checks (SAST scan);
    - automatic versioning;
    ? GitLab & Docker cleanup;

# Detailed To-Dos

+ setup Gitlab CI / CD:      // gitlab/ verified end to end: setup_gitlab.sh + docker-smoke-test.sh
    + `gitlab/.env` for keeping all GitLab-related documentation (add `gitlab/.env.example` as a reference);
    + containerized deployment:
        + pinned image tag;
        + tuned `gitlab.rb` (populate from .env, minimize RAM consumption);
    + configure (add idempotent bash script(-s)):
        + auth (add GitLab admin, project owner and developer);
        + containerized runner manager for the project (instance-scoped, Docker executor);
        + render `gitlab.rb` & runner config from `gitlab/.env`;
    + no environments;      // deployment state is the nginx config
    + no CI/CD variables;     // no registry; prod credentials live in the compose file

+ setup project:
    + store project configuration:
        + `project/.env` with example file for configuration;
        + testing configuration may be partially or fully overridden by GitLab;
        + deployment configuration may be partially or fully overridden by docker-compose.yml;

    + project source code:
        + simple FastAPI app:
            + read configuration with Pydantic Settings;
            + Postgres as DB + async SQLAlchemy & Alembic;
            + a single `users` table with Alembic migration;
            + app setup & teardown;
            + create operation for the `users` table;
            + `GET /health`;        // used as the deployment readiness gate
            x Dockerfile;
        + tests:
            + fixtures and test utilities;
            + integration tests for `users` route handler;
            + run against a per-job `postgres` service container;
    
    + configure linting & type checking;

+ implement `gitlab/setup_project.sh` script:
    + registers (or resets via delete) project in GitLab:
        + only main branch is sent, other branches should be pushed manually when testing corresponding scenarios;
        + branch protection:
            + main: only owner can merge, no one can push;
            + other branches: owner and developer can push;
    + create (or reset) a dev repo copy:
        + temp/repo_copies/dev;
        + contains all branches;
        + has GitLab's repo as its only remote;

+ add cleanup script:
    + stop and remove containers (but keep images);
    + remove all files in temp dir;

x add script(-s) for resetting project state to default;    // partial reset can be achieved by running setup scripts, full reset - by running cleanup -> setup scripts




- implement basic merge request flow:
    - update job container (or add another) to allow running API project-related checks;
    - jobs in the flow:
        - linting & type checking;
        - tests;
    - should forbid merge if any errors occur ("Pipelines must succeed");
    - check if postgres service container does not publish any ports on host;   // so there are no conflicts between simultaneously running services

- additional branches for testing (scenarios, deferred):
    - a valid feature branch:
        - `items` table + create route handler;
        - integration tests for new route handler;
    - an invalid feature branch:
        - additional test case that intentionally fails;
    x a branch with a new db migration; // should be covered by valid feature branch


- implement a few scenarios for testing CI:
    - use temp directory to setup developer's repo copy:
        - use the copy to push branches to GL and trigger merge requests;
    - scenarios:
        - valid app update merge request;
        - broken app update merge request;
        - new db migration merge request;
        ? deployment of a commit to prod;   // or trigger via GL UI instead
        ? db migration upgrade / downgrade;
    - scenarios should be implemented as automated scripts and/or markdown with instructions on how to run them;

- test scripts:
    - 2 test jobs can work simultaneously;
    - main branch in GL is protected from being into;

- configure deployment flow for the project:
    - add blue-green deployment;        // Nginx + 2 app containers + db (named volume), one compose project;
    - deployment flow:
        - triggered manually;
        - is parametrized with commit to deploy & flag to deploy blue or green container (manual job, runtime variables);
        - build a production image for the specified commit;
        - start the target container and wait for `GET /health`;
        - redirect nginx to the correct container (render the conf, then `nginx -s reload`);
        - stop the other container;
        - guard deploy & migrate jobs with `resource_group`;
    
- configure db migrations flow:
    - flow:
        - accepts migration name and direction (upgrade / downgrade) as params ;
        - run through a one-shot `migrate` service, using the image of the target commit;
        - manual `upgrade` / `downgrade` to a specific revision;

- script for resetting prod to default state:
    ? merge with setup project;

- remove prod containers in cleanup script;
- ensure all runner containers are deleted by cleanup;
