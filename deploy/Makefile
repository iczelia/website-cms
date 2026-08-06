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

# Podman is the only supported deployment shape.

REPO := $(shell cd .. && pwd)

QUADLET_DIR ?= $(HOME)/.config/containers/systemd
TAG         ?= localhost/iczelia:latest
NAME        ?= iczelia
VOL         ?= iczelia-state

.PHONY: tinyllm podman-help podman-build podman-run podman-up podman-stop \
        podman-restart podman-shell podman-logs podman-passwd \
        podman-fetch podman-db podman-clean podman-status podman-quadlet

# Fetch + convert arnir0/Tiny-LLM into share/tinyllm/ so the AI-slop bot
# trap has weights to run against. Run before building the image.
# Idempotent; safe to re-run.
tinyllm:
	perl $(REPO)/bin/iczelia-tinyllm-convert

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
