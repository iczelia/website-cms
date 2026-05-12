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

set -euo pipefail

CONFIG=/etc/iczelia/iczelia.conf
VAR=/var/lib/iczelia

# Make sure the volume is laid out (a fresh volume mount is empty).
install -d -m 0755 "$VAR" "$VAR/media" "$VAR/tmp"

# Cookie secret: 32 random bytes, hex-encoded. Generated once and persisted.
SECRET="$VAR/cookie-secret"
if [ ! -s "$SECRET" ]; then
    perl -e '
        open my $f, "<:raw", "/dev/urandom" or die $!;
        my $b; sysread $f, $b, 32; close $f;
        print unpack "H*", $b;
    ' > "$SECRET.tmp"
    mv "$SECRET.tmp" "$SECRET"
    chmod 0600 "$SECRET"
fi

# DB initialization on first boot (idempotent - schema uses IF NOT EXISTS).
/opt/iczelia/bin/iczelia-init --config "$CONFIG"

cmd="${1:-server}"

case "$cmd" in
  server)
    # Background fetcher: every 10 min. Skips silently on first 60s.
    # tini -g forwards signals to the whole process group so this dies
    # cleanly with the server.
    (
      trap 'exit 0' TERM INT
      sleep 60 & wait $!
      while true; do
        /opt/iczelia/bin/iczelia-fetch-activity --config "$CONFIG" \
          >/dev/stderr 2>&1 || true
        sleep 600 & wait $!
      done
    ) &

    exec /opt/iczelia/bin/iczelia-server --config "$CONFIG"
    ;;

  passwd)
    shift
    exec /opt/iczelia/bin/iczelia-passwd --config "$CONFIG" "$@"
    ;;

  init)
    exec /opt/iczelia/bin/iczelia-init --config "$CONFIG" "${@:2}"
    ;;

  fetch)
    exec /opt/iczelia/bin/iczelia-fetch-activity --config "$CONFIG" --verbose
    ;;

  shell|bash)
    exec /bin/bash
    ;;

  *)
    # Pass-through: run an arbitrary command (mostly for debugging).
    exec "$@"
    ;;
esac
