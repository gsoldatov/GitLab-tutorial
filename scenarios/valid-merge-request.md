# Overview

The scenario runs a merge request of a valid feature.

Feature is present in `valid-feature` branch and introduces a new table, route handler and tests for the API project.

# Workflow

1. Push branch to GitLab from the dev's repo:
    ```bash
    cd "temp/repo_copies/dev"
    BRANCH="valid-feature"
    git push -u origin "$BRANCH"
    ```

2. Open the merge request to `main` as the developer.

3. Wait for pipeline complete and merge branch as Owner.
