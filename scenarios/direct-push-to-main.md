# Overview

The scenario checks that direct push of a new commit to `main` branch is prohibited.

# Workflow

1. Commit and attempt a push to GitLab from the dev's repo:
    ```bash
    cd "temp/repo_copies/dev"
    git switch main
    git pull origin main
    git commit --allow-empty -m "test commit"
    git push -u origin main
    ```

2. Reset to a previous commit:
    ```bash
    git reset --hard HEAD~1
    ```
