#!/usr/bin/env bash
# One-time setup of real HTTPS certificates on the staging VM. Run as root,
# after install.sh staging:
#   sudo ./staging-tls.sh
#
# Let's Encrypt cannot reach the intranet VM, so it checks a DNS record instead.
# Each site's _acme-challenge name is a CNAME to an acme-dns account, which this
# VM may update and nothing else. The VM never holds a key to campusmotion.ch.
# Safe to run again: it keeps the existing account.
set -euo pipefail

ACME_DNS=https://auth.acme-dns.io
ACCOUNT=/root/acme-dns.json
ENV_FILE=/etc/caddy/acme-dns.env
CADDYFILE=/etc/caddy/Caddyfile

fail() { echo "staging-tls.sh: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "run with sudo"
[[ "$(cat /etc/campus-motion/environment 2> /dev/null)" == staging ]] || fail "run install.sh staging first"
command -v python3 > /dev/null || fail "python3 is needed"

# 1. A Caddy build with the acme-dns module, kept apart from the Debian package
# so that apt upgrades do not replace it.
if ! caddy list-modules 2> /dev/null | grep -q '^dns.providers.acmedns$'; then
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) fail "unsupported architecture $(uname -m)" ;;
  esac
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "https://caddyserver.com/api/download?os=linux&arch=$arch&p=github.com/caddy-dns/acmedns"
  chmod 755 "$tmp"
  "$tmp" list-modules | grep -q '^dns.providers.acmedns$' || fail "the downloaded Caddy has no acmedns module"
  [[ -e /usr/bin/caddy.default ]] || dpkg-divert --divert /usr/bin/caddy.default --rename /usr/bin/caddy
  mv "$tmp" /usr/bin/caddy.custom
  update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.default 10
  update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.custom 50
fi

# 2. The acme-dns account, usable only from this VM's public IPv4 address.
if [[ ! -s "$ACCOUNT" ]]; then
  ip=$(curl -4 -fsS https://ifconfig.me)
  [[ "$ip" =~ ^[0-9.]+$ ]] || fail "could not find this VM's public IPv4 address"
  install -m 600 /dev/null "$ACCOUNT"
  curl -4 -fsS -X POST "$ACME_DNS/register" -H 'Content-Type: application/json' \
    -d "{\"allowfrom\":[\"$ip/32\"]}" > "$ACCOUNT"
fi
install -m 600 /dev/null "$ENV_FILE"
python3 - "$ACCOUNT" "$ENV_FILE" << 'EOF'
import json, sys
account = json.load(open(sys.argv[1]))
with open(sys.argv[2], 'w') as f:
    for key in ('username', 'password', 'subdomain'):
        f.write(f"ACMEDNS_{key.upper()}={account[key]}\n")
EOF

# 3. Caddy reads the credentials from the environment, never from the Caddyfile.
install -d -m 755 /etc/systemd/system/caddy.service.d
printf '[Service]\nEnvironmentFile=%s\n' "$ENV_FILE" > /etc/systemd/system/caddy.service.d/acme-dns.conf
systemctl daemon-reload

# 4. The staging_tls snippet that add-site.sh puts in each site. It must come
# before the sites are imported. Caddy's own DNS check is skipped because this
# VM cannot query outside name servers; Let's Encrypt still checks the record.
if ! grep -q '^(staging_tls)' "$CADDYFILE"; then
  tmp=$(mktemp)
  cat > "$tmp" << EOF
(staging_tls) {
	tls {
		dns acmedns {
			username {\$ACMEDNS_USERNAME}
			password {\$ACMEDNS_PASSWORD}
			subdomain {\$ACMEDNS_SUBDOMAIN}
			server_url $ACME_DNS
		}
		propagation_delay 10s
		propagation_timeout -1
	}
}

EOF
  cat "$CADDYFILE" >> "$tmp"
  install -m 644 "$tmp" "$CADDYFILE"
  rm -f "$tmp"
fi
# shellcheck source=/dev/null
(set -a; . "$ENV_FILE"; set +a; caddy validate --config "$CADDYFILE" --adapter caddyfile > /dev/null)
systemctl restart caddy

target=$(python3 -c "import json; print(json.load(open('$ACCOUNT'))['fulldomain'])")
cat << EOF

Done. For each staging site, add at Hostinger, next to its A record:
  _acme-challenge.<site>.staging   CNAME   $target
New sites get it automatically from add-site.sh (certificate type "dns").
EOF
