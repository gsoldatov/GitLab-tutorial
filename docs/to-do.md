# Overview

- setup & configure GitLab in Docker container;
- setup Python API project with a PostgreSQL db & tests;
- configure project repo to be managed by GitLab;
- configure jobs for merge request (linting & tests);
- configure jobs for deploying:
    - blue / green deployment (Nginx + 2 API containers + db container) on the same machine (separately from GL container(-s));
    - jobs:
        - deploy a commit to blue / green & switch between containers;
        - upgrade / downgrade to a specific db migration;
? configure additional jobs:
    ? security checks (SAST scan);
    ? GitLab cleanup;
    ? automatic versioning;

# Detailed To-Dos

- setup Gitlab CI / CD:
    - containerized deployment;
    - configure (add an idempotent bash script):
        - auth (add GitLab admin, project owner and developer);
        - containerized runner executor for the project;
        ? environments;     // tests should be done in runner, prod should be run via Docker, so not needed?
        ???

- setup project:
    - store project configuration:
        - project configuration itself should be in a .env file inside its dir;
        - TODO specify a way to store configurations used in different jobs:
            - use cases:
                - tests;    // may need to specify test db URL, when running it in a different container
                - db migrations in prod;        // need db URL and credentials
                - deploying an app in prod;     // need to provide full configuration to the app
            ? setup variables in GitLab when configuring project;
            ? other options for passing variables;

    - project source code:
        - simple FastAPI app:
            - read configuration via .env;
            - Postgres as DB + SQLAlchemy;
            - a single `users` table with Alembic migration;
            - app setup & teardown;
            - CRUD operations for the `users` table;
        - tests:
            - fixtures and test utilities;
            - integration tests for `users` route handlers in separate files;
    
    - additional branches for testing:
        - a valid feature branch:
            - `items` table + CRUD route handlers;
            - integration tests for new route handlers;;
        - an invalid feature branch:
            - additional test case that intentionally fails;
    
    - setup project copies:
        - add a bash script for to create or reset repo copies;
        - repo copies are stored inside a gitignored directory;
        - dev repo copy;
        ? owner repo copy;   // if it's needed for the merge request
        ? gitlab repo copy:
            - or add it to gitlab's storage;
            - GitLab copy should have main branch only and any applied merges should be reset;
        ? add dev / owner containers;   // or interact with it from localhost

- implement basic merge request flow:
    - branch protection:
        - main: only owner can merge, no one can push;
        - other branches: owner and developer can push;
    - jobs in the flow:
        - linting & type checking;
        - tests;
    
    - should forbid merge if any errors occur;

- configure deployment flow for the project:
    - add blue-green deployment;    // Nginx + 2 containers
    - deployment flow:
        - is parametrized with commit to deploy & flag to deploy blue or green container;
        - deploy a container with a specific commit;
        - redirect nginx to the correct container after its parametrized;
        - stop the other container;

- implement a few scenarios for testing CI:
    - in separate branches:
        - valid app update;
        - broken app update;
        - new db migration;
    - scripts and or markdown with instructions on how to run them;
    
- add script(-s) for resetting project state to default:
    // so that scenarios could be run repeatedly and won't interfere with each other
    - reuse / upate existing scripts;
    - reset project configuration & repo in GitLab;
    - reset repo copies;
    - reset production containers;

? add security check job:
    ? add this (and other reusable) jobs as CI/CD components;   // or include local files
? add a job for running db migrations:
    // or plan how they should run
    - upgrade to specific revision;
    - downgrade to specific revision;

? periodic Docker cleanup;
? automatic versioning job;
