# Overview

The scenario provides an example on how to handle merge conflicts between two branches.

The conflict is simulated by subsequently merging `valid-feature` and `valid-conflicting-feature` branches.

The first branch adds a new table, a route handler and tests for it.

The second branch adds the same table, but with a renamed column, a different route handler and tests for it.

Successfully renaming requires to resolve conflicts caused by changes (keep one name of the column and both route handlers) and then making sure all test cases pass (by fixing remaining column name inconsistencies).

# Workflow

1. Push `valid-feature` and complete a successful merge request (see [valid-merge-request.md](valid-merge-request.md)).

2. Push `valid-conflicting-feature` and open an MR, similar to `valid-feature`.

3. Resolve merge conflicts:

  - option A: resolve locally:
    - pull `main` and `valid-conflicting-feature`:
      ```bash
      # Pull main branch updates
      git checkout main
      git fetch origin
      ```
    - merge `main` into `valid-conflicting-feature` and resolve conflicts:
      ```bash
      git checkout valid-conflicting-branch
      git merge main
      ```

  - option B: resolve in GitLab's web editor and commit.

4. Fix test errors locally or in GitLab's web editor.

5. Wait for the CI checks to pass for the latest commit.

6. Merge the branch as Owner.
