# Basic Plan (Local Deployment + Containers)

## 🛠️ Step 1: Local Environment & Prerequisites

Before touching GitLab, ensure the local machine is ready to act as both the development environment and the deployment server.
    [1](https://blog.devops.dev/gitlab-ci-cd-pipeline-deploy-to-staging-production-environment-97c679fb8408),
    [2](https://www.testmuai.com/blog/use-gitlab-ci-to-run-test-locally/)

- Install Docker & Docker Compose: Verify installations using `docker --version` and `docker compose version`.
- Create a Sample Application: Set up a simple project (e.g., Node.js, Python, or Go) with a working local server.
- Write a Dockerfile: Ensure the application can be built into an image and runs cleanly on port 80 or 8080.
- Configure local environment variables: Create a template .env.example file for tutorial users to reference.

[1](https://levelup.gitconnected.com/production-ready-ci-cd-with-docker-on-gitlab-practical-guide-316283dccc98),
[2](https://blog.devops.dev/gitlab-ci-cd-pipeline-deploy-to-staging-production-environment-97c679fb8408)

## 💻 Step 2: Local GitLab Runner Setup

To run the pipeline and handle local container operations, a local GitLab Runner is required.
    [1](https://about.gitlab.com/blog/getting-started-with-gitlab-understanding-ci-cd/),
    [2](https://www.testmuai.com/blog/use-gitlab-ci-to-run-test-locally/)

- Install GitLab Runner: Install the binary or run GitLab Runner inside a separate Docker container.
    [1](https://www.testmuai.com/blog/use-gitlab-ci-to-run-test-locally/)

- Select the Executor:
    - Use the Docker executor if you want jobs to run isolated inside containers.
    - Use the Shell executor if your deployment strategy relies on the runner executing native `docker compose up` commands directly on the host machine.
    [1](https://docs.gitlab.com/ci/),
    [2](https://www.testmuai.com/blog/use-gitlab-ci-to-run-test-locally/)

- Register the Runner: Connect the local runner to the GitLab tutorial project using the registration token provided in **Settings > CI/CD > Runners**.
    [1](https://www.testmuai.com/blog/use-gitlab-ci-to-run-test-locally/)

- Configure Docker-in-Docker (Optional): If using the Docker executor to build Docker images, ensure the `privileged = true` flag is enabled in the runner's config.toml.

## 📝 Step 3: CI/CD Configuration (.gitlab-ci.yml)

Define the pipeline workflow in the root of the project repository.
    [1](https://about.gitlab.com/blog/getting-started-with-gitlab-understanding-ci-cd/)

- Define Pipeline Stages: Establish an organized `flow: stages: [build, test, deploy]`.
- Standardize Caching: Configure caching for package dependencies (e.g., node_modules or .pip-cache) to speed up builds.
- Pin Image Versions: Explicitly define exact versions for pipeline images (e.g., `docker:24.0.7` instead of `docker:latest`) to prevent future breaking changes.
    [1](https://www.grizzlypeaksoftware.com/library/gitlab-cicd-pipeline-configuration-watqqoh7),
    [2](https://about.gitlab.com/blog/getting-started-with-gitlab-understanding-ci-cd/)

## 📦 Step 4: Build & Registry Stage

Build the container and store it cleanly.
    [1](https://goregulus.com/cra-basics/gitlab-container-registry/),
    [2](https://levelup.gitconnected.com/production-ready-ci-cd-with-docker-on-gitlab-practical-guide-316283dccc98)

- Authenticate with GitLab Registry: Use pre-defined variables (`$CI_REGISTRY_USER` and `$CI_REGISTRY_PASSWORD`) to log into the GitLab Container Registry.
- Build and Tag the Image: Use the commit SHA (`$CI_COMMIT_SHORT_SHA`) or branch names to tag the container build dynamically.
- Push to Registry: Push the newly created image back to GitLab's built-in registry so it can be pulled during the deployment step.
    [1](https://goregulus.com/cra-basics/gitlab-container-registry/),
    [2](https://levelup.gitconnected.com/production-ready-ci-cd-with-docker-on-gitlab-practical-guide-316283dccc98)

## 🚀 Step 5: Local Deployment Stage

Bring the container down to the local host environment.
    [1](https://docs.gitlab.com/ci/),
    [2] (https://blog.devops.dev/gitlab-ci-cd-pipeline-deploy-to-staging-production-environment-97c679fb8408)

- Set Environment Rules: Ensure the deployment job only runs on the main or master branch using rules: syntax.
- Clean Up Existing Containers: Add logic to safely stop and remove previous containers (`docker stop app || true`) to prevent port conflicts.
- Pull and Run: Pull the latest built container from the registry and launch it locally (`docker run -d -p 80:80 ...`).
- Use GitLab Environments: Bind the deployment job to a tracking environment (e.g., `environment: name: local_dev`) so history can be tracked directly from the GitLab UI. 
    [1](https://www.linkedin.com/posts/sher-ali-khan-5b6279198_gitlab-production-deployment-checklist-activity-7361816957857222657-nQvE),
    [2](https://www.grizzlypeaksoftware.com/library/gitlab-cicd-pipeline-configuration-watqqoh7)


## 🔐 Step 6: Security & Validation
Keep credentials clean and confirm the tutorial works end-to-end.
    [1](https://levelup.gitconnected.com/production-ready-ci-cd-with-docker-on-gitlab-practical-guide-316283dccc98),
    [2](https://www.linkedin.com/posts/sher-ali-khan-5b6279198_gitlab-production-deployment-checklist-activity-7361816957857222657-nQvE)

- Mask & Protect Secrets: Move any sensitive API keys or database passwords out of the code and into GitLab CI/CD Variables.
- Pipeline Execution Test: Trigger the pipeline via a fresh `git push` and visually audit the progress under **Build > Pipelines**.
- Local Verification: Access the locally deployed container in a web browser (e.g., http://localhost:8080) to ensure everything handles traffic correctly.
    [1](https://docs.gitlab.com/ci/quick_start/),
    [2](https://www.linkedin.com/posts/sher-ali-khan-5b6279198_gitlab-production-deployment-checklist-activity-7361816957857222657-nQvE),
    [3](https://levelup.gitconnected.com/production-ready-ci-cd-with-docker-on-gitlab-practical-guide-316283dccc98),
    [4](https://blog.devops.dev/gitlab-ci-cd-pipeline-deploy-to-staging-production-environment-97c679fb8408)

# Advanced

## 🛡️ 1. Security & Code Quality Flows (DevSecOps)

These jobs run in parallel with tests or immediately after the build to catch issues before deployment.

- Container Vulnerability Scanning: Use tools like Trivy or GitLab's native container scanning to audit your built Docker image layers for known vulnerabilities.
- Static Application Security Testing (SAST): Integrate linters or security scanners (like Semgrep or SonarQube) to analyze raw source code for hardcoded secrets or insecure patterns.
- Dependency Scanning & License Compliance: Run checks (like `npm audit` or `pip-audit`) to ensure third-party packages don't introduce security flaws or compliance risks.

## 🔄 2. Advanced Deployment & Rollback Flows

Local single-container deployments often suffer from downtime during updates. These flows solve that.

- Zero-Downtime Deployment (Blue/Green): Use a local reverse proxy (like Nginx or Traefik) to seamlessly route traffic from an old container ("Blue") to a new container ("Green") only after the new one passes health checks.
- Automated Rollback on Failure: Add an on_failure job in GitLab CI that automatically executes a script to pull and run the previous stable Docker image tag if the deployment or post-deployment health check fails.
- Post-Deployment Health Checks: Implement a job that pings your locally deployed application's /health endpoint using curl to verify it is actually accepting traffic before marking the pipeline as successful.

## 🧹 3. Local Resource Maintenance Flows

Running continuous deployments locally will quickly bloat the host machine's storage with dangling Docker layers.

- Automated Docker Cleanup (Prune): Create a cleanup job or a scheduled pipeline (GitLab CI Cron) that runs `docker system prune -f` or `docker image prune` to delete untagged images and free up local disk space.
- Registry Clean up: Implement a stage that interacts with the GitLab API to clean up older, redundant image tags in the GitLab Container Registry.

## 🏷️ 4. Release Automation & Versioning Flows

Teach users how to move away from using latest tags and instead adopt strict version management.

- Semantic Versioning (SemVer): Integrate **Semantic Release** or **commitlint**. When code is merged into main, the pipeline automatically reads conventional commit messages, calculates the next version (e.g., v1.2.0), creates a Git tag, and builds the container with that exact version tag.
- Changelog Generation: Automatically compile a markdown CHANGELOG.md document based on commit history and attach it to a GitLab Release page.

## 📊 Summary: How to Structure an Advanced Multi-Stage Pipeline

A robust, production-ready pipeline combining these flows would look like this:

| Stage | Job / Flow Description | Key Benefit | 
| --- | --- | --- | 
| Lint & Scan | Code linting + SAST scanning | Catches code quality and security bugs early. |
| Build | Compile app + build temporary container image | Prepares the artifact for verification. |
| Verify | Container scanning (Trivy) + Unit/Integration tests | Ensures the container image itself is secure and stable. |
| Release | Tag image with SemVer + Push to GitLab Registry | Guarantees immutable, traceable release versions. |
| Deploy | Blue/Green local deployment + Post-deploy curl check | Deploys with zero user downtime and verifies availability. |
| Cleanup | `docker image prune` on the local runner | Prevents the local machine from running out of disk space. |
