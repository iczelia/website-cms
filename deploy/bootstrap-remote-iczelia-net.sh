#!/usr/bin/env bash
# iczelia.net - personal CMS and static site engine.
# Copyright (C) 2026 Kamila Szewczyk
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# Full end-to-end deploy to a FRESH machine (Debian/Ubuntu, root SSH).
# Provisions host packages, builds the podman image, installs the daemon
# as a systemd-managed container, obtains TLS certs, wires up the nginx
# vhost, and sets the admin password. Idempotent: safe to re-run.
#
# For incremental updates of an already-provisioned box, use
# deploy-remote-iczelia-net.sh instead.
#
# Usage:
#   ./deploy/bootstrap-remote-iczelia-net.sh [--skip-build] [--no-tls]
#
# Options:
#   --skip-build   Reuse the existing image; skip podman build.
#   --no-tls       Skip certbot and the nginx vhost; daemon stays on
#                  127.0.0.1:8731 only. Wire up your own proxy/TLS later.
#
# Environment overrides:
#   REMOTE         SSH target              (default: root@13.140.186.200)
#   REMOTE_SRC     Source dir on host      (default: /opt/iczelia-src)
#   REMOTE_TAG     Image tag               (default: localhost/iczelia:latest)
#   REMOTE_SVC     Systemd unit name       (default: iczelia)
#   DOMAIN         Public hostname         (default: iczelia.net)
#   EMAIL          Let's Encrypt contact   (default: none, registers w/o email)
#   ADMIN_PASSWORD Admin password to set   (default: random, printed once)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

REMOTE="${REMOTE:-root@13.140.186.200}"
REMOTE_SRC="${REMOTE_SRC:-/opt/iczelia-src}"
REMOTE_TAG="${REMOTE_TAG:-localhost/iczelia:latest}"
REMOTE_SVC="${REMOTE_SVC:-iczelia}"
DOMAIN="${DOMAIN:-iczelia.net}"
EMAIL="${EMAIL:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

SKIP_BUILD=0
DO_TLS=1
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        --no-tls)     DO_TLS=0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

BUNDLE="$(mktemp /tmp/iczelia-src-XXXXXX.tar.gz)"
REMOTE_RUN="$(mktemp /tmp/iczelia-bootstrap-XXXXXX.sh)"
trap 'rm -f "$BUNDLE" "$REMOTE_RUN"' EXIT

# Build the remote script locally: config baked in as quoted assignments
# (no positional args over ssh, so empty/space-y values can't get lost or
# split), followed by the literal body. printf %q makes every value a
# safe single token regardless of contents.
{
    printf 'set -euo pipefail\n'
    printf 'REMOTE_SRC=%q\n'     "$REMOTE_SRC"
    printf 'REMOTE_TAG=%q\n'     "$REMOTE_TAG"
    printf 'REMOTE_SVC=%q\n'     "$REMOTE_SVC"
    printf 'DOMAIN=%q\n'         "$DOMAIN"
    printf 'EMAIL=%q\n'          "$EMAIL"
    printf 'ADMIN_PASSWORD=%q\n' "$ADMIN_PASSWORD"
    printf 'SKIP_BUILD=%q\n'     "$SKIP_BUILD"
    printf 'DO_TLS=%q\n'         "$DO_TLS"
    cat <<'REMOTE_SCRIPT'

step() { printf '\n--- %s\n' "$*"; }

step "Installing host packages (podman, nginx, certbot)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
PKGS="podman nginx curl ca-certificates openssl"
[ "$DO_TLS" = "1" ] && PKGS="$PKGS certbot python3-certbot-nginx"
apt-get install -y --no-install-recommends $PKGS
PODMAN="$(command -v podman)"

step "Removing any stray native ${REMOTE_SVC}.service (it shadows the container)..."
# A leftover native unit running /opt/iczelia/bin/iczelia-server would
# win over the quadlet-generated unit of the same name. Clear it out.
if [ -f "/etc/systemd/system/${REMOTE_SVC}.service" ]; then
    systemctl disable --now "${REMOTE_SVC}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${REMOTE_SVC}.service"
    systemctl daemon-reload
fi

step "Unpacking source into $REMOTE_SRC..."
mkdir -p "$REMOTE_SRC"
tar -xzf /tmp/iczelia-src.tar.gz -C "$REMOTE_SRC"
rm -f /tmp/iczelia-src.tar.gz

if [ "$SKIP_BUILD" = "0" ]; then
    step "Building image ($REMOTE_TAG)... (texlive pull, can take a few minutes)"
    "$PODMAN" build -t "$REMOTE_TAG" -f "$REMOTE_SRC/deploy/Containerfile" "$REMOTE_SRC"
else
    step "Skipping podman build (--skip-build)."
fi

step "Installing the daemon as a systemd-managed container..."
install -d -m 0755 /etc/containers/systemd
cp "$REMOTE_SRC/deploy/iczelia.container" "/etc/containers/systemd/${REMOTE_SVC}.container"
systemctl daemon-reload

# Quadlet (podman >= 4.4) generates ${REMOTE_SVC}.service from the
# .container file above. On older podman the generator is absent, so the
# unit never materialises; fall back to a conventional `podman run` unit.
if ! systemctl cat "${REMOTE_SVC}.service" >/dev/null 2>&1; then
    echo "    Quadlet unsupported on this podman; writing a podman-run unit."
    rm -f "/etc/containers/systemd/${REMOTE_SVC}.container"
    cat > "/etc/systemd/system/${REMOTE_SVC}.service" <<UNIT
[Unit]
Description=iczelia.net (Podman)
After=network-online.target
Wants=network-online.target

[Service]
Restart=on-failure
RestartSec=2
TimeoutStartSec=600
ExecStartPre=-${PODMAN} rm -f ${REMOTE_SVC}
ExecStart=${PODMAN} run --replace --name ${REMOTE_SVC} --rm \\
    -p 127.0.0.1:8731:8731 \\
    -v iczelia-state:/var/lib/iczelia:Z \\
    ${REMOTE_TAG}
ExecStop=${PODMAN} stop ${REMOTE_SVC}

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable "${REMOTE_SVC}.service"
fi

step "Starting $REMOTE_SVC..."
systemctl reset-failed "${REMOTE_SVC}.service" 2>/dev/null || true
systemctl restart "${REMOTE_SVC}.service"

step "Waiting for the daemon to answer on 127.0.0.1:8731..."
ok=0
for i in $(seq 1 30); do
    if curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:8731/; then ok=1; break; fi
    sleep 1
done
if [ "$ok" != "1" ]; then
    echo "ERROR: daemon did not come up." >&2
    systemctl --no-pager -l status "${REMOTE_SVC}.service" || true
    journalctl -u "${REMOTE_SVC}.service" -n 60 --no-pager || true
    exit 1
fi
echo "    OK: daemon is serving."

step "Bootstrapping admin password..."
# Only set on first provision; never clobber an existing password. The
# marker lives in the state volume so re-runs are no-ops.
if "$PODMAN" exec "$REMOTE_SVC" test -s /var/lib/iczelia/auth-bootstrapped 2>/dev/null; then
    echo "    Password already set (marker present); leaving it untouched."
else
    PW="$ADMIN_PASSWORD"
    GENERATED=0
    if [ -z "$PW" ]; then
        PW="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
        GENERATED=1
    fi
    if printf '%s\n%s\n' "$PW" "$PW" \
         | "$PODMAN" exec -i "$REMOTE_SVC" /usr/local/bin/iczelia-entrypoint passwd >/dev/null 2>&1; then
        "$PODMAN" exec "$REMOTE_SVC" sh -c 'touch /var/lib/iczelia/auth-bootstrapped' 2>/dev/null || true
        if [ "$GENERATED" = "1" ]; then
            echo "    Generated admin password: $PW   (change it after first login)"
        else
            echo "    Admin password set from \$ADMIN_PASSWORD."
        fi
    else
        echo "WARN: could not set admin password; run it by hand:" >&2
        echo "      $PODMAN exec -it $REMOTE_SVC /usr/local/bin/iczelia-entrypoint passwd" >&2
    fi
fi

if [ "$DO_TLS" = "1" ]; then
    step "Ensuring TLS certificate for $DOMAIN..."
    LIVE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    if [ ! -f "$LIVE" ]; then
        # certonly --standalone needs port 80 free; nginx may hold it.
        if [ -n "$EMAIL" ]; then CB_EMAIL=(-m "$EMAIL"); else CB_EMAIL=(--register-unsafely-without-email); fi
        systemctl stop nginx 2>/dev/null || true
        certbot certonly --standalone --non-interactive --agree-tos \
            "${CB_EMAIL[@]}" -d "$DOMAIN" \
            || echo "WARN: certbot failed (does $DOMAIN point at this host? is :80 reachable?)" >&2
        systemctl start nginx 2>/dev/null || true
    else
        echo "    Certificate already present."
    fi

    # The vhost references these two helper files; certbot's certonly path
    # does not always drop them, so synthesise sane ones when missing.
    if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
        SRC=/usr/lib/python3/dist-packages/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf
        if [ -f "$SRC" ]; then
            cp "$SRC" /etc/letsencrypt/options-ssl-nginx.conf
        else
            cat > /etc/letsencrypt/options-ssl-nginx.conf <<'TLSOPT'
ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
TLSOPT
        fi
    fi
    [ -f /etc/letsencrypt/ssl-dhparams.pem ] || openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048

    if [ -f "$LIVE" ]; then
        step "Installing nginx vhost and reloading..."
        cp "$REMOTE_SRC/deploy/nginx-iczelia-net.conf" /etc/nginx/conf.d/iczelia-net.conf
        if nginx -t; then
            systemctl reload nginx
            echo "    OK: nginx reloaded."
        else
            echo "WARN: nginx -t failed; vhost installed but NOT reloaded. Fix and 'systemctl reload nginx'." >&2
        fi
    else
        echo "WARN: no certificate for $DOMAIN; skipping nginx vhost." >&2
        echo "      Once DNS points here, re-run this script (or just the cert + nginx steps)." >&2
    fi
else
    step "Skipping TLS / nginx (--no-tls). Daemon is on 127.0.0.1:8731 only."
fi

step "Done."
echo "    Service:  systemctl status $REMOTE_SVC"
echo "    Logs:     journalctl -u $REMOTE_SVC -f"
REMOTE_SCRIPT
} > "$REMOTE_RUN"

echo "==> Validating generated remote script..."
bash -n "$REMOTE_RUN"

echo "==> Bundling source..."
tar -czf "$BUNDLE" \
    --exclude='./.git' \
    --exclude='./share/chrome/.git' \
    --exclude='./attic' \
    --exclude='./var' \
    --exclude='*.bak' \
    --exclude='*.orig' \
    --exclude='*.tmp' \
    -C "$ROOT" .
printf "    %s\n" "$(du -h "$BUNDLE" | cut -f1) compressed"

echo "==> Uploading to $REMOTE..."
scp -q "$BUNDLE"     "${REMOTE}:/tmp/iczelia-src.tar.gz"
scp -q "$REMOTE_RUN" "${REMOTE}:/tmp/iczelia-bootstrap.sh"

echo "==> Provisioning $REMOTE (fresh-machine bootstrap)..."
ssh "$REMOTE" bash /tmp/iczelia-bootstrap.sh

echo
echo "==> Bootstrap complete."
echo "    Public:   https://$DOMAIN/         (once DNS + TLS are in place)"
echo "    Local:    http://127.0.0.1:8731/   (on the host)"
echo "    Tail logs: ssh $REMOTE 'journalctl -u $REMOTE_SVC -f --no-pager'"
