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

# Quick-start: run the iczelia container detached, with a named volume
# for state. Use this only for "kick the tires" - for production prefer
# the Quadlet unit at deploy/iczelia.container.
set -euo pipefail

TAG="${TAG:-localhost/iczelia:latest}"
NAME="${NAME:-iczelia}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8731}"
VOL="${VOL:-iczelia-state}"

# Ensure the volume exists.
podman volume inspect "$VOL" >/dev/null 2>&1 || podman volume create "$VOL"

podman run -d --rm \
    --name "$NAME" \
    -p "${HOST}:${PORT}:8731" \
    -v "$VOL:/var/lib/iczelia:Z" \
    "$TAG"

echo "iczelia is up: http://${HOST}:${PORT}/"
echo "set the admin password:"
echo "  podman exec -it $NAME /usr/local/bin/iczelia-entrypoint passwd"
