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

# Push local source to the production server and restart the daemon.
#
# Usage:
#   ./deploy/deploy-remote.sh [--skip-build]
#
# Options:
#   --skip-build   Unpack + restart only; skip podman build.
#                  Use this when only Perl/templates/chrome changed and
#                  no new system deps were introduced.
#
# Environment overrides:
#   REMOTE         SSH target          (default: ubuntu@iczelia.net)
#   REMOTE_SRC     Source dir on host  (default: /opt/iczelia-src)
#   REMOTE_TAG     Image tag           (default: localhost/iczelia:latest)
#   REMOTE_SVC     Systemd unit name   (default: iczelia)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

REMOTE="${REMOTE:-ubuntu@iczelia.net}"
REMOTE_SRC="${REMOTE_SRC:-/opt/iczelia-src}"
REMOTE_TAG="${REMOTE_TAG:-localhost/iczelia:latest}"
REMOTE_SVC="${REMOTE_SVC:-iczelia}"

SKIP_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

BUNDLE="$(mktemp /tmp/iczelia-src-XXXXXX.tar.gz)"
trap 'rm -f "$BUNDLE"' EXIT

echo "==> Bundling source..."
tar -vczf "$BUNDLE" \
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
scp -q "$BUNDLE" "${REMOTE}:/tmp/iczelia-src.tar.gz"

echo "==> Deploying on $REMOTE..."
ssh "$REMOTE" bash -s -- "$REMOTE_SRC" "$REMOTE_TAG" "$REMOTE_SVC" "$SKIP_BUILD" <<'REMOTE_SCRIPT'
set -euo pipefail
REMOTE_SRC="$1"; REMOTE_TAG="$2"; REMOTE_SVC="$3"; SKIP_BUILD="$4"

echo "--- Unpacking source into $REMOTE_SRC..."
sudo tar -xzf /tmp/iczelia-src.tar.gz -C "$REMOTE_SRC"
rm -f /tmp/iczelia-src.tar.gz

if [ "$SKIP_BUILD" = "0" ]; then
    echo "--- Building image ($REMOTE_TAG)..."
    sudo podman build -t "$REMOTE_TAG" \
        -f "$REMOTE_SRC/deploy/Containerfile" \
        "$REMOTE_SRC"
else
    echo "--- Skipping podman build (--skip-build)."
fi

echo "--- Restarting $REMOTE_SVC, clearing nginx cache..."
sudo systemctl restart "$REMOTE_SVC"
sudo rm -rf /var/cache/nginx/iczelia/* && sudo systemctl reload nginx

echo "--- Waiting for service to stabilise..."
sleep 3
sudo systemctl is-active --quiet "$REMOTE_SVC" \
    && echo "    OK: $REMOTE_SVC is active." \
    || { echo "ERROR: $REMOTE_SVC failed to start."; sudo journalctl -u "$REMOTE_SVC" -n 40 --no-pager; exit 1; }
REMOTE_SCRIPT

echo "==> Deploy complete."
echo "    Tail logs: ssh $REMOTE 'sudo journalctl -u $REMOTE_SVC -f --no-pager'"
