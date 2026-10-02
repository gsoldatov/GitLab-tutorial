# Overview

This directory contains instructions on how to run several CI scenarios and observe their results.
Scenarios are intended to be executed manually, using a copy of this repository, CLI and GitLab's UI.

# Scenario Workflow

Scenarios are independent from each other, although some of them may overlap.

General workflow implies that:
- GitLab is configured and running;
- repository copies in GitLab and `temp/` dir are restored to default state.

The following bash scripts should be used to achieve that state:
- `gitlab/setup_gitlab.sh` - run once to setup or update GitLab and its executor;
- `gitlab/setup_project.sh` - run to restore repo copies to default state before each scenario is started;

After this, follow the instructions inside a specific scenario file.

`gitlab/cleanup.sh` can be called after work with the project is complete to remove Docker assets used by this project (base images are kept; the API images the jobs built are removed) and delete `temp/` dir.

# Project Architecture

This project uses a single machine setup with Docker. The following containers are created on the host machine:
- GitLab & GitLab Runner;
- job and service containers;
- project deployment containers (Nginx, blue/green containers, DB);
- optionally, a DB container for running tests locally.

## Project Pipeline and Configuration in GitLab

- `project/` dir contains a small Python API, which uses a PostgreSQL DB and acts as a "separate" project, managed by GitLab;
- `project/.gitlab-ci.yml` file contains the pipeline with CI and deployment jobs;
- project is worked on by the following users (credentials are in `gitlab/.env`):
  - `Developer`: does commits in repository clone and opens merge requests in GitLab;
  - `Owner`: maintains the project in GitLab and accepts merge requests;
- project uses the following branching approach:
  - `main`: project's main branch with the stable code;
  - feature branches: contain working (or not) functionality that is merged into `main`;
  - direct pushes to `main` are forbidden;
  - by default only `main` is present in GitLab's repo.
