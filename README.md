# website-cms

Personal CMS and dynamic site engine behind nginx. Pure-Perl backend
(DBI/SQLite + system TeX), CMS for editing pages and posts, and a
zero-JavaScript public surface. Math is rendered server-side via
`latex` + `dvisvgm` and cached in SQLite. The CMS uses vendored
CodeMirror 5 + marked.js (under `share/web/vendor/`).

Licensed under the GNU AGPL v3 or later. See [LICENSE.md](./LICENSE.md).

## Requirements

Distro packages (Debian-flavoured names):

- `perl` >= 5.10
- `libdbi-perl`, `libdbd-sqlite3-perl`
- `nginx`
- `texlive-latex-base`, `texlive-latex-recommended`,
  `texlive-fonts-recommended`, `texlive-latex-extra`
- `dvisvgm`
- `curl`
- `cron` (for the activity fetcher)

## Layout

    bin/                     CLI entry points
      iczelia-server         the daemon
      iczelia-init           create the SQLite database
      iczelia-passwd         set or change the admin password
      iczelia-fetch-activity cron entry point for GitHub/Mastodon/Bluesky
      iczelia-update         fast-forward the checkout to the latest patch release
    lib/Iczelia/             Perl modules
    share/
      schema.sql             DDL applied by iczelia-init
      seed.sql               default settings + empty pages
      templates/             template engine views (.tpl) + page schemas (.json)
      web/                   cms.css, cms.js, vendor/ (CodeMirror, marked.js)
      chrome/                static visual chrome (CSS, fonts, asset packs)
    t/                       test suite (Test::More)
    deploy/                  systemd unit, nginx site, tmpfiles, cron, install Makefile

## Quick start (development)

    bin/iczelia-init --force        # creates ./var/site.db
    bin/iczelia-passwd              # admin password (>= 8 chars)
    bin/iczelia-server --listen 127.0.0.1:8731 --workers 1
    # then open http://127.0.0.1:8731/admin/login

## Tests

    make test                       # full t/ suite, ~10s with TeX

## Production install

Two supported deployment shapes.

### A. Podman / rootless container (recommended)

Bundles TeX Live and all Perl deps inside the image (~700 MB). Host
needs `podman` and `nginx`. State (DB + media) lives in a named volume.

One-time host setup, if you've never run rootless podman before:

    sudo usermod --add-subuids 100000-165535 \
                 --add-subgids 100000-165535 iczelia
    podman system migrate

Build and run:

    cd deploy
    ./podman-build.sh                   # builds localhost/iczelia:latest
    ./podman-run.sh                     # runs detached on 0.0.0.0:8731
    podman exec -it iczelia /usr/local/bin/iczelia-entrypoint passwd

Quadlet (Podman >= 4.4):

    make podman-quadlet
    systemctl --user enable --now iczelia

Front it with the host's nginx using `deploy/nginx.conf` as a
template. The daemon serves chrome, cms.css/js, vendored JS, and
`/media/` itself; nginx just terminates TLS and runs an edge
proxy_cache.

### B. Native systemd install (`make install`)

    cd deploy
    make install             # uses sudo; installs to /opt/iczelia, /var/lib/iczelia
    sudo nginx -t && sudo systemctl reload nginx
    sudo systemctl enable --now iczelia
    sudo systemctl daemon-reload
    sudo systemd-tmpfiles --create
    sudo -u iczelia /opt/iczelia/bin/iczelia-passwd

Default config lands at `/etc/iczelia/iczelia.conf`. Edit the SSL
paths in `/etc/nginx/sites-available/iczelia.conf` for your certificate.

## Operating

- Daemon listens on `/run/iczelia/sock` by default and serves
  everything (chrome, /media/, dynamic routes). nginx terminates TLS
  and runs an edge `proxy_cache`.
- nginx caches public GETs for 5 minutes; the daemon and the activity
  fetcher `PURGE` paths after writes via a loopback-only endpoint.
- `/etc/cron.d/iczelia` runs the fetcher every 10 minutes. Configure
  `github.username`, `mastodon.feed_url`, `bluesky.handle` in
  `/admin/settings/`.
- Math fragments are content-addressed in `tex_cache`. Oldest unused
  entries can be cleaned periodically:
  `DELETE FROM tex_cache WHERE created_at < strftime('%s','now') - 7*86400`.

## Updates

`bin/iczelia-update` keeps a git-based deployment current. It fetches
the `release` branch, reads `lib/Iczelia.pm`'s `$VERSION` there, and
only when that is a *patch-level* bump over the running version (the
`z` in `x.y.z` moved forward and `x.y` is unchanged) and the working
tree is clean, it fast-forwards the checkout to it. Minor/major bumps,
downgrades, local edits and diverged history are reported and left for
a human; `--dry-run` reports without changing anything.

After a successful update it runs the command in `update-restart-cmd`
(empty by default), e.g. `sudo systemctl restart iczelia`. Branch and
remote are `update-branch` / `update-remote` (default `release` on
`origin`; set `update-remote=` empty to track a purely local branch).

This only makes sense when the code is a git checkout. The `make
install` and Podman shapes copy a snapshot of the code, so update them
by pulling this repo and re-running `make install` / rebuilding the
image. To wire it up on a checkout-based deployment:

    */30 * * * * iczelia /path/to/checkout/bin/iczelia-update --config /etc/iczelia/iczelia.conf --quiet

## Backups

The state-of-the-world is two paths:

- `/var/lib/iczelia/site.db` (sqlite; use `sqlite3 .backup` or `cp`
  while the daemon is briefly stopped)
- `/var/lib/iczelia/media/` (uploaded images)

Everything else (code, templates, vendor JS) is in this repo.

## Artwork

The artwork and CSS of https://iczelia.net was deliberately not included
in this repository and the author explicitly prohibits reproduction of
the site's visual design via copying of CSS or assets. Users are welcome
to supply their own CSS and artwork in `/share/chrome` - without it,
the site will be functional (for some definition of this word) but
visually unstyled.
