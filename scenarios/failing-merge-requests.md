# Overview

The scenario simulates a merge request that initially fails one of the CI jobs.

The following git branches are up to use during the scenario:
- `failing-linting`: a file containing an unused import;
- `failing-typecheck`: a file containing a wrong type hints for a function;
- `failing-tests`: a file containing a failing test case.

# Workflow

The workflow is similar for each of the branches.

1. Push branch to GitLab from the dev's repo:
    ```bash
    cd "temp/repo_copies/dev"
    BRANCH="failing-linting"
    git push -u origin "$BRANCH"
    ```

2. Open the merge request to `main` as the developer.

3. Open the pipeline from the merge request's reports section and find the failing job.

4. Add a commit that fixes the error and push it to GitLab.
    ```bash
    git add -A
    git commit -m "Fixed errors"
    ```

5. Wait for pipeline complete and merge branch as Owner.
