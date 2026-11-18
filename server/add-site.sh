#!/usr/bin/env bash
# Adds a project to this VM. Run as an admin, on the staging VM and on the
# production VM:
#   sudo ./add-site.sh
# It asks a few questions, then creates:
#   /srv/sites/<site>/docker-compose.yml and app.env
#   /etc/caddy/sites/<site>.caddy
set -euo pipefail

SITES_DIR=/srv/sites
fail() { echo "add-site.sh: $*" >&2; exit 1; }
ask() { local answer; read -rp "$1${2:+ [$2]}: " answer; echo "${answer:-$2}"; }

[[ $EUID -eq 0 ]] || fail "run with sudo"
here=$(cd "$(dirname "$0")" && pwd)
environment=$(cat /etc/campus-motion/environment 2> /dev/null || true)
[[ -n "$environment" ]] || fail "run install.sh on this VM first"
echo "This VM hosts: $environment"

site=$(ask "Site name, the same on both VMs (lowercase letters, digits and dashes)")
[[ "$site" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || fail "invalid site name"
[[ ! -e "$SITES_DIR/$site" ]] || fail "site '$site' already exists on this VM"
repo=$(ask "GitHub repository in the Campus-Motion organisation" "$site")
[[ "$repo" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid repository name"
container_port=$(ask "Port the app listens on inside its container" 3000)
[[ "$container_port" =~ ^[0-9]+$ ]] || fail "invalid port"
domain=$(ask "Domain of the $environment site (e.g. admin.example.ch)")
[[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || fail "invalid domain"

# Public VMs get certificates automatically. Intranet VMs cannot, so they use
# Caddy's own authority (browsers warn) or certificate files from EPFL IT.
default_tls=auto
[[ "$environment" == staging ]] && default_tls=internal
tls_mode=$(ask "HTTPS certificate: auto, internal, or files" "$default_tls")
case "$tls_mode" in
  auto) tls_line="" ;;
  internal) tls_line="tls internal" ;;
  files)
    cert=$(ask "Path to the certificate file (PEM)")
    key=$(ask "Path to the private key file (PEM)")
    [[ -f "$cert" && -f "$key" ]] || fail "certificate or key file not found"
    tls_line="tls $cert $key" ;;
  *) fail "answer auto, internal or files" ;;
esac

# Next free host port, after the ones used by existing sites.
last=$(grep -rhoE '127\.0\.0\.1:[0-9]+' "$SITES_DIR" 2> /dev/null | cut -d: -f2 | sort -n | tail -n 1 || true)
port=$(( ${last:-8099} + 1 ))

dir="$SITES_DIR/$site"
install -d -m 750 -o github-deploy -g github-deploy "$dir"
sed -e "s|@PROJECT@|$site-$environment|" -e "s|@IMAGE@|ghcr.io/campus-motion/${repo,,}|" \
    -e "s|@HOST_PORT@|$port|" -e "s|@CONTAINER_PORT@|$container_port|" \
    "$here/templates/docker-compose.yml" > "$dir/docker-compose.yml"
chown github-deploy:github-deploy "$dir/docker-compose.yml"
install -m 600 -o github-deploy -g github-deploy /dev/null "$dir/app.env"

sed -e "s|@DOMAIN@|$domain|" -e "s|@PORT@|$port|" -e "s|@TLS@|$tls_line|" \
    "$here/templates/site.caddy" > "/etc/caddy/sites/$site.caddy"
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null
systemctl reload caddy

cat << EOF

Site '$site' is ready on this $environment VM: https://$domain -> 127.0.0.1:$port

Next steps:
  1. Put the app's settings and secrets in $dir/app.env.
     Staging and production must use different values.
  2. If the app needs a database, add it to $dir/docker-compose.yml (see README).
  3. Point $domain to this VM in DNS.
  4. Run add-site.sh on the other VM with the same site name, if not done yet.
EOF
