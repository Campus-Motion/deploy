#!/usr/bin/env bash
# One-time setup of a VM. Run as an admin, once per VM:
#   production VM: sudo ./install.sh production production_deploy_key.pub
#   staging VM:    sudo ./install.sh staging
#
# Creates the github-deploy user, the only account that can run containers for
# the pipeline, and installs cm-deploy as the only thing the pipeline can run.
# Safe to run again.
set -euo pipefail

fail() { echo "install.sh: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "run with sudo"
environment=${1:-}
[[ "$environment" == staging || "$environment" == production ]] \
  || fail "usage: sudo ./install.sh production <public key file> | sudo ./install.sh staging"
if [[ "$environment" == production ]]; then
  pubkey_file=${2:-}
  [[ -f "$pubkey_file" ]] || fail "give the public key file of the production deploy key"
  pubkey=$(head -n 1 "$pubkey_file")
  [[ "$pubkey" == ssh-ed25519\ * ]] || fail "$pubkey_file is not an ed25519 public key"
fi

here=$(cd "$(dirname "$0")" && pwd)

command -v docker > /dev/null || fail "Docker is not installed"
docker compose version > /dev/null || fail "the Docker Compose plugin is not installed"
command -v caddy > /dev/null || fail "Caddy is not installed: see https://caddyserver.com/docs/install#debian-ubuntu-raspbian"

install -d -m 755 /etc/campus-motion
echo "$environment" > /etc/campus-motion/environment

# github-deploy has no password. Being in the docker group is equivalent to
# root, which is why the pipeline can only reach it through cm-deploy.
id github-deploy > /dev/null 2>&1 || adduser --disabled-password --gecos "" github-deploy
usermod -aG docker github-deploy
install -m 755 "$here/cm-deploy" /usr/local/bin/cm-deploy
install -d -m 755 -o github-deploy -g github-deploy /srv/sites

if [[ "$environment" == production ]]; then
  # GitHub reaches production over SSH, with a key limited to cm-deploy.
  install -d -m 700 -o github-deploy -g github-deploy /home/github-deploy/.ssh
  echo "command=\"/usr/local/bin/cm-deploy\",restrict $pubkey" > /home/github-deploy/.ssh/authorized_keys
  chown github-deploy:github-deploy /home/github-deploy/.ssh/authorized_keys
  chmod 600 /home/github-deploy/.ssh/authorized_keys
else
  # Staging is on the intranet: a GitHub runner on this VM runs the job as the
  # unprivileged github-runner user, which may only start cm-deploy.
  id github-runner > /dev/null 2>&1 || adduser --disabled-password --gecos "" github-runner
  sudoers=$(mktemp)
  echo "github-runner ALL=(github-deploy) NOPASSWD: /usr/local/bin/cm-deploy" > "$sudoers"
  visudo -cf "$sudoers" > /dev/null || fail "invalid sudoers rule"
  install -m 440 "$sudoers" /etc/sudoers.d/campus-motion-deploy
  rm -f "$sudoers"
fi

# Caddy: one file per site in /etc/caddy/sites.
install -d -m 755 /etc/caddy/sites
grep -q '^import /etc/caddy/sites/\*.caddy' /etc/caddy/Caddyfile \
  || printf '\nimport /etc/caddy/sites/*.caddy\n' >> /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null
systemctl reload caddy

if [[ "$environment" == production ]]; then
  echo "Done. Set PRODUCTION_HOST and PRODUCTION_KNOWN_HOSTS in GitHub (see README), then add sites with add-site.sh."
else
  echo "Done. Register the GitHub runner as the github-runner user, run staging-tls.sh (see README), then add sites with add-site.sh."
fi
