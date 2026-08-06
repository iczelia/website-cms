# website-cms

Personal CMS and dynamic site engine behind nginx. Pure-Perl backend
(DBI/SQLite + system TeX), CMS for editing pages and posts, and a
zero-JavaScript public surface. Math is rendered server-side via
`latex` + `dvisvgm` and cached in SQLite. The CMS uses vendored
CodeMirror 5 + marked.js (under `share/web/vendor/`).

Licensed under the GNU AGPL v3 or later. See [LICENSE.md](./LICENSE.md).

## Requirements

Perl modules: see `cpanfile` (DBI, DBD::SQLite, IO::Compress::Brotli;
everything else the daemon uses is core). Install with `cpanm
--installdeps .` (or `make deps`); the container build does this.

Distro packages (Debian-flavoured names):

- `perl` >= 5.10, plus a C toolchain to build the cpanfile deps
  (`build-essential`, `libperl-dev`, `libbrotli-dev`, `cpanminus`)
- `libbrotli1` (runtime for `IO::Compress::Brotli`)
- `nginx`
- `texlive-latex-base`, `texlive-latex-recommended`,
  `texlive-fonts-recommended`, `texlive-latex-extra`
- `dvisvgm`
- `curl`
- `cron` (for the activity fetcher)
- optional: `zopfli`, `oxipng` (tighter gzip / PNG, used by the cache warmer)

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
    deploy/                  Containerfile, podman quadlet + scripts, nginx site, remote deploy scripts

Things that contain `iczelia-net` in their name are specific to the public-facing deployment at
https://iczelia.net and can be safely ignored or deleted for a personal deployment. They however
may contain some useful reference material for nginx config and the like.

## Quick start (development)

    bin/iczelia-init --force        # creates ./var/site.db
    bin/iczelia-passwd              # admin password (>= 8 chars)
    bin/iczelia-server --listen 127.0.0.1:8731 --workers 1
    # then open http://127.0.0.1:8731/admin/login

## Tests

    make test                       # full t/ suite, ~10s with TeX

## Production install

Podman is the only supported shape. For a fresh remote host, run
`deploy/bootstrap-remote-iczelia-net.sh` (it provisions packages, builds
the image, installs the quadlet, obtains TLS, and wires up nginx); push
later updates with `deploy/deploy-remote-iczelia-net.sh`. The steps below
are the same thing done by hand, and for local use.

### Podman container

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

Front it with the host's nginx using `deploy/nginx-iczelia-net.conf` as
a template. The daemon serves chrome, cms.css/js, vendored JS, and
`/media/` itself, and owns all caching; nginx just terminates TLS and
reverse-proxies to `127.0.0.1:8731`.

## Operating

- Daemon listens on `127.0.0.1:8731` (TCP) by default and serves
  everything (chrome, /media/, dynamic routes); it owns all caching.
  nginx terminates TLS and reverse-proxies to it.
- The container entrypoint (`deploy/entrypoint.sh`) runs the activity
  fetcher every 10 minutes. Configure `github.username`,
  `mastodon.feed_url`, `bluesky.handle` in `/admin/settings/`.
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

This only makes sense when the code is a git checkout. The Podman shape
copies a snapshot of the code, so update it by pulling this repo and
rebuilding the image (or run `deploy/deploy-remote-iczelia-net.sh`). To
wire it up on a checkout-based deployment:

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
