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

PERL ?= perl
PROVE ?= prove

.PHONY: test test-quick test-tex check run clean

check:
	@$(PERL) -Ilib -c bin/iczelia-server
	@bin/iczelia-server --check

test:
	@$(PROVE) -l --jobs 4 t/

test-quick:
	@$(PROVE) -l --jobs 4 -e '$(PERL) -Ilib' t/0*.t t/1*.t

run:
	@bin/iczelia-server --listen 127.0.0.1:8731

clean:
	@find . -name '*.tmp.*' -delete
	@rm -rf var/site.db var/tmp/*
