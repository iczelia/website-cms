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

PREFIX     ?= /opt/iczelia
VARDIR     ?= /var/lib/iczelia
CONFDIR    ?= /etc/iczelia
NGINX_DIR  ?= /etc/nginx/sites-available
SYSTEMD_DIR?= /etc/systemd/system
TMPFILES_DIR ?= /etc/tmpfiles.d
CRON_DIR   ?= /etc/cron.d
USER       ?= iczelia

REPO := $(shell cd .. && pwd)

.PHONY: install deps user dirs files conf nginx systemd cron db perms tinyllm \
        inline podman-build podman-run podman-quadlet podman-stop

deps:
	sudo cpanm --installdeps $(REPO)

# Fetch + convert arnir0/Tiny-LLM into share/tinyllm/ so the AI-slop bot
# trap has weights to run against. Idempotent; safe to re-run.
tinyllm:
	perl $(REPO)/bin/iczelia-tinyllm-convert

# Pre-compile the Inline::C inference engine as the daemon user, so the
# systemd sandbox (MemoryDenyWriteExecute=true) never has to invoke gcc
# at request time. Idempotent: once the .so is cached, this is a no-op.
inline:
	sudo -u $(USER) PERL5LIB=$(PREFIX)/lib \
	    perl -MIczelia::Slop::Model -e1 || \
	    echo "WARN: inline pre-compile failed (the slop trap will fail at runtime)"

install: deps user dirs files conf nginx systemd cron db perms inline
	@echo
	@echo "==> Done. Next steps:"
	@echo "    1) sudo systemctl daemon-reload && sudo systemctl enable --now iczelia"
	@echo "    2) sudo systemd-tmpfiles --create"
	@echo "    3) sudo nginx -t && sudo systemctl reload nginx"
	@echo "    4) sudo -u $(USER) $(PREFIX)/bin/iczelia-passwd"
	@if [ ! -s $(PREFIX)/share/tinyllm/weights.bin ]; then \
	  echo "    5) (optional) make tinyllm && sudo make files  # enable AI-slop bot trap"; \
	fi

user:
	@id -u $(USER) >/dev/null 2>&1 || sudo useradd --system --shell /usr/sbin/nologin --home-dir $(VARDIR) $(USER)

dirs:
	sudo install -d -o $(USER) -g $(USER) -m 0755 $(PREFIX) $(PREFIX)/bin $(PREFIX)/lib $(PREFIX)/share
	# _Inline is the Inline::C compilation cache for the AI-slop bot
	# trap; the daemon user needs to be able to write here on first
	# compile (subsequent loads are read-only).
	sudo install -d -o $(USER) -g $(USER) -m 0755 $(PREFIX)/_Inline
	sudo install -d -o $(USER) -g $(USER) -m 0755 $(VARDIR) $(VARDIR)/media $(VARDIR)/tmp $(VARDIR)/git
	sudo install -d -o root -g root -m 0755 $(CONFDIR)

files:
	sudo cp -r $(REPO)/bin/.   $(PREFIX)/bin/
	sudo cp -r $(REPO)/lib/.   $(PREFIX)/lib/
	sudo cp -r $(REPO)/share/. $(PREFIX)/share/
	sudo chown -R root:root $(PREFIX)/bin $(PREFIX)/lib $(PREFIX)/share
	sudo chmod 755 $(PREFIX)/bin/*

conf:
	@if [ ! -f $(CONFDIR)/iczelia.conf ]; then \
	  echo "==> Installing default config to $(CONFDIR)/iczelia.conf"; \
	  sudo cp deploy/iczelia.conf $(CONFDIR)/iczelia.conf; \
	  sudo chown root:$(USER) $(CONFDIR)/iczelia.conf; \
	  sudo chmod 0640 $(CONFDIR)/iczelia.conf; \
	else \
	  echo "==> Existing $(CONFDIR)/iczelia.conf preserved."; \
	fi

nginx:
	sudo cp deploy/nginx.conf $(NGINX_DIR)/iczelia.conf
	sudo ln -sf $(NGINX_DIR)/iczelia.conf /etc/nginx/sites-enabled/iczelia.conf

systemd:
	sudo cp deploy/iczelia.service  $(SYSTEMD_DIR)/iczelia.service
	sudo cp deploy/iczelia.tmpfiles $(TMPFILES_DIR)/iczelia.conf

cron:
	sudo cp deploy/iczelia.cron $(CRON_DIR)/iczelia

db:
	sudo -u $(USER) $(PREFIX)/bin/iczelia-init --config $(CONFDIR)/iczelia.conf || true

perms:
	sudo chown -R $(USER):$(USER) $(VARDIR)
	sudo chmod 0755 $(VARDIR)
	sudo chmod 0700 $(VARDIR)/cookie-secret 2>/dev/null || true

uninstall:
	sudo systemctl disable --now iczelia 2>/dev/null || true
	sudo rm -f $(SYSTEMD_DIR)/iczelia.service \
	            $(TMPFILES_DIR)/iczelia.conf \
	            $(CRON_DIR)/iczelia \
	            $(NGINX_DIR)/iczelia.conf \
	            /etc/nginx/sites-enabled/iczelia.conf
	sudo rm -rf $(PREFIX)
	@echo "(left $(VARDIR) and $(CONFDIR) intact; remove manually if desired)"

QUADLET_DIR ?= $(HOME)/.config/containers/systemd
TAG         ?= localhost/iczelia:latest
NAME        ?= iczelia
VOL         ?= iczelia-state

.PHONY: podman-help podman-build podman-run podman-up podman-stop \
        podman-restart podman-shell podman-logs podman-passwd \
        podman-fetch podman-db podman-clean podman-status podman-quadlet

podman-help:
	@echo "Podman targets:"
	@echo "  podman-build     build the image"
	@echo "  podman-run       build + start the container detached"
	@echo "  podman-up        build + start + attach to logs (one command kick-the-tires)"
	@echo "  podman-stop      stop + remove the container (state preserved)"
	@echo "  podman-restart   stop + run"
	@echo "  podman-status    one-line summary"
	@echo "  podman-logs      follow daemon logs"
	@echo "  podman-shell     interactive bash inside the container"
	@echo "  podman-passwd    set / change the admin password (interactive)"
	@echo "  podman-fetch     run the activity fetcher once, verbosely"
	@echo "  podman-db        open the SQLite shell against the live DB"
	@echo "  podman-clean     stop, remove container AND volume (DESTRUCTIVE)"
	@echo "  podman-quadlet   install systemd --user unit"

podman-build:
	./podman-build.sh

podman-run: podman-build
	./podman-run.sh

# Build the image, (re-)create the container with state, ensure the
# admin password exists, and tail the daemon logs in the foreground.
# Ctrl-C detaches you from the logs but the container keeps running.
podman-up:
	@$(MAKE) podman-stop  >/dev/null 2>&1 || true
	@$(MAKE) podman-build
	@./podman-run.sh
	@echo
	@echo "==> http://127.0.0.1:8731/         (public site)"
	@echo "==> http://127.0.0.1:8731/admin/   (login: admin / hunterhunter or set yours via 'make podman-passwd')"
	@echo "==> Following daemon logs (Ctrl-C detaches; container keeps running):"
	@echo
	@if ! podman exec $(NAME) test -s /var/lib/iczelia/auth-bootstrapped 2>/dev/null; then \
	    echo 'hunterhunter\nhunterhunter' | podman exec -i $(NAME) /usr/local/bin/iczelia-entrypoint passwd >/dev/null 2>&1 \
	    && podman exec $(NAME) sh -c 'touch /var/lib/iczelia/auth-bootstrapped' 2>/dev/null \
	    && echo "==> Default admin password set to 'hunterhunter' (change it!)"; \
	fi
	@podman logs -f $(NAME)

podman-stop:
	-podman stop $(NAME) 2>/dev/null
	-podman rm   $(NAME) 2>/dev/null

podman-restart: podman-stop podman-run

podman-status:
	@podman ps --filter name=^$(NAME)$$ --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true

podman-logs:
	podman logs -f $(NAME)

podman-shell:
	podman exec -it $(NAME) bash

podman-passwd:
	podman exec -it $(NAME) /usr/local/bin/iczelia-entrypoint passwd

podman-fetch:
	podman exec -it $(NAME) /usr/local/bin/iczelia-entrypoint fetch

podman-db:
	podman exec -it $(NAME) sqlite3 /var/lib/iczelia/site.db

podman-clean: podman-stop
	-podman volume rm $(VOL)

podman-quadlet:
	install -d $(QUADLET_DIR)
	cp iczelia.container $(QUADLET_DIR)/iczelia.container
	systemctl --user daemon-reload
	@echo "==> Now: systemctl --user enable --now iczelia"
	@echo "    then: podman exec -it systemd-iczelia /usr/local/bin/iczelia-entrypoint passwd"
