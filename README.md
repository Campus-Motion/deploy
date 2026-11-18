# Campus Motion deploy

One way to deploy every Campus Motion project.

- Every project has two branches: `main` is **staging**, `production` is the **live site**.
- Merging into `main` deploys to staging automatically.
- Going live, and undoing a release, are buttons in GitHub. Nobody needs to log into a VM.

```
merge into main ──> image built and tagged with the commit ──> staging VM (EPFL intranet)
"Promote to production" button ──> same commit ──> production VM (public)
"Rollback" button ──> an earlier image ──> staging or production
```

| | Staging | Production |
|---|---|---|
| VM | EPFL intranet VM, reachable only from the EPFL network or VPN | Public VM |
| Addresses | `<site>.staging.campusmotion.ch` | `<site>.campusmotion.ch` or the project's own domain |
| How GitHub deploys | A GitHub runner installed on the VM picks the job up | Over SSH, with a key that can only run `cm-deploy` |
| HTTPS certificate | Caddy's own (`tls internal`): browsers show a warning | Automatic (Let's Encrypt) |

This repository is public on purpose: it holds no secrets and no server addresses, and public reusable workflows work for both public and private repositories.

## Day to day (everyone)

All of this happens in the project's page on GitHub, in the **Actions** tab, workflow **Deploy**.

| I want to | Do this |
|---|---|
| Put my change on staging | Merge your pull request into `main`. Watch the Deploy run in the Actions tab. |
| Put staging live | Actions > Deploy > **Run workflow** > `promote-to-production` > Run. |
| Undo a bad release | Find the previous good deploy in the Actions tab and copy its commit (7 characters are enough). Actions > Deploy > Run workflow > `rollback-production` (or `rollback-staging`), paste the commit, Run. |
| Know if something failed | GitHub emails the person who started the run. The run page says what went wrong. |

Only people with the **Maintain** or **Admin** role on the repository can change production. Everyone else can deploy to staging.

Staging is only reachable from the EPFL network or the EPFL VPN.

### If "promote" fails with "production has commits that are not on main"

Someone pushed a fix directly to `production`. Open a pull request from `production` into `main`, merge it, then promote again.

## Add a new project

You need an admin who can log into both VMs for steps 2 and 3.

1. **Dockerfile.** The project must build with Docker. Start from an existing project if you are unsure.
2. **On each VM** (staging, then production): go to this repository's `server` folder on the VM (`git clone` it the first time, `git pull` after) and run `sudo ./add-site.sh`. Give the **same site name** on both VMs. It asks for the GitHub repository, the port the app uses inside its container, the domain, and the certificate type (keep the default).
3. **Settings and secrets:** fill in `/srv/sites/<site>/app.env` on each VM. Use **different** values on each: staging must never use the production database or production keys.
4. **DNS:** staging names under `staging.campusmotion.ch` already work (see one-time setup). For production, add an `A` record for the domain pointing to the production VM.
5. **In the project repository:** copy [templates/deploy.yml](templates/deploy.yml) to `.github/workflows/deploy.yml` and change the lines marked `CHANGE`. If the build needs a setting such as an API address, use `staging-build-args` and `production-build-args`. Only public values go there: they end up inside the image. Secrets go in `app.env`.
6. **First deploy:** merge the pull request that adds `deploy.yml` into `main`. To create the `production` branch the first time, run `promote-to-production`.

### Projects with a database or several containers

`add-site.sh` creates one `app` container. To add a database, edit `/srv/sites/<site>/docker-compose.yml` on each VM, for example:

```yaml
services:
  app:
    # ...as created by add-site.sh...
    depends_on:
      db:
        condition: service_healthy
  db:
    image: postgres:16-alpine
    env_file: app.env
    volumes:
      - db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER}"]
      interval: 5s
      retries: 10
    restart: unless-stopped
volumes:
  db:
```

Rules for these files:

- Do not publish database ports (no `ports:` on `db`). The app reaches it by the name `db`.
- Do not set `container_name`. Names must stay unique per VM, and Compose already makes them unique.
- To run a one-off job (for example from cron), use the same image: `image: ghcr.io/campus-motion/<repo>:${IMAGE_TAG}` with its own `command:`.

## One-time setup (organisation admin)

Done once for the whole organisation. Redo the step for a VM only if that VM is replaced.

### Production VM

1. **Deploy key.** On your computer:

   ```bash
   ssh-keygen -t ed25519 -N "" -C "campus-motion-production-deploy" -f production_deploy_key
   ```

2. **VM.** Install Docker, the Compose plugin and Caddy. Clone this repository on the VM, copy `production_deploy_key.pub` there, and in the `server` folder run:

   ```bash
   sudo ./install.sh production production_deploy_key.pub
   ```

   This creates a `github-deploy` user with no password, whose key can only run `cm-deploy`. Even if the key leaks, it can only redeploy images that already exist.

3. **GitHub organisation settings > Secrets and variables > Actions:**
   - Secret `PRODUCTION_SSH_KEY`: the content of `production_deploy_key` (the private key). Then delete the file from your computer.
   - Variable `PRODUCTION_HOST`: the production VM's IP address.
   - Variable `PRODUCTION_KNOWN_HOSTS`: the output of `ssh-keyscan -t ed25519 <production VM address>`. Check that its fingerprint matches what `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints on the VM.

   If a private repository's run says `PRODUCTION_SSH_KEY` is missing, the organisation's plan does not share secrets with private repositories. Add the same secret and variables in that repository's settings.

### Staging VM (EPFL intranet)

1. **VM.** Install Docker, the Compose plugin and Caddy. Clone this repository on the VM and in the `server` folder run:

   ```bash
   sudo ./install.sh staging
   ```

   This creates `github-deploy` (runs the containers) and `github-runner` (runs the GitHub runner). `github-runner` has no rights of its own: it may only start `cm-deploy`.

2. **GitHub runner.** In the organisation settings > Actions > Runners > New runner > Linux, GitHub shows the commands to download and configure it. Run them **as `github-runner`** (`sudo -iu github-runner`), and when asked for labels, enter `campus-motion-staging`. Then install it as a service, from the runner folder:

   ```bash
   sudo ./svc.sh install github-runner && sudo ./svc.sh start
   ```

   In Settings > Actions > Runner groups, the group must allow **public repositories**, since several projects are public.

3. **DNS** at Hostinger, once for all projects:

   ```
   *.staging.campusmotion.ch   A   <staging VM address (128.178.x.x)>
   ```

### Keeping the runner safe

The runner runs code from GitHub inside the EPFL network. Agree on it with EPFL IT first, and keep these settings:

- In each public repository: Settings > Actions > General > **Require approval for all external contributors**. A pull request from outside the organisation then cannot run anything on the runner without a maintainer's approval.
- Do not use the `campus-motion-staging` label in any other workflow. Only the central pipeline should run on it.
- Treat staging as if it were public: login required in the apps, fake data only.

### Releasing this repository

Projects use `@v1`. Only organisation owners can create or move `v*` tags.

## Changing the pipeline (maintainers of this repository)

A change here reaches projects only when the `v1` tag moves.

- **Fix or small improvement:** merge through a pull request, test it on one project by pointing its `deploy.yml` at your branch (`@your-branch` instead of `@v1`), then an owner moves the tag:

  ```bash
  git tag -f v1 origin/main && git push -f origin v1
  ```

- **Change that requires projects to edit their `deploy.yml`:** release `v2` and migrate projects one by one.

## Troubleshooting

| Message | Meaning |
|---|---|
| `Only maintainers and admins can change production` | Ask a maintainer to run it, or to give you the Maintain role. |
| `PRODUCTION_SSH_KEY, PRODUCTION_HOST or PRODUCTION_KNOWN_HOSTS is missing` | See one-time setup, production VM, step 3. |
| Staging deploy stays "Waiting for a runner" | The runner on the staging VM is stopped, or its group does not allow this repository. On the VM: `sudo systemctl status 'actions.runner.*'`. |
| `unknown site` | The `site:` in `deploy.yml` does not match a name given to `add-site.sh` on that VM. |
| `this VM hosts 'staging', not production` | `PRODUCTION_HOST` points to the staging VM. |
| `Host key verification failed` | The production VM was replaced or reinstalled. Update `PRODUCTION_KNOWN_HOSTS`. |
| `does not answer after the deploy` | The app started badly. Look at its logs on the VM (`docker compose logs` in `/srv/sites/<site>`), and roll back if needed. |

On each VM, `/srv/sites/<site>/deploy.log` lists every deploy with the previous and new version.
