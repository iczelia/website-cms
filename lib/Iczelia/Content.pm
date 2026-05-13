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

package Iczelia::Content;
use strict;
use warnings;
use Carp qw(croak);

# CRUD over pages, posts, updates, activity, webring, settings.
# Mutating methods invalidate caches via the injected $render.
#
# Package layout (Iczelia::Content is split across 9 files; all reopen
# this package). Each fragment touches only $self->{db} and (where
# relevant) $self->{render} for cache invalidation. No cross-file
# helper calls; readers can locate any method by name below.
#
#   Content.pm           new (this file).
#   Content/Pages.pm     get_page, save_page.
#   Content/Posts.pm     get_post, list_posts, create_post, update_post,
#                        delete_post, list_aliases, list_revisions,
#                        get_revision, delete_alias, normalize_publish_at,
#                        _word_count.
#   Content/Dynamic.pm   validate_dynamic_route, list_dynamic_pages,
#                        get_dynamic_page, get_dynamic_page_by_route,
#                        create_dynamic_page, update_dynamic_page,
#                        delete_dynamic_page, _validate_template.
#   Content/Langs.pm     list_langs, get_lang, create_lang, update_lang,
#                        delete_lang, _validate_lang_name,
#                        _validate_lang_record.
#   Content/Media.pm     list_media, get_media, create_media, delete_media.
#   Content/Activity.pm  list_activity, list_updates, replace_updates,
#                        set_currently.
#   Content/Webring.pm   list_webring, replace_webring.
#   Content/Settings.pm  all_settings, set_settings.

sub new {
  my ($class, %arg) = @_;
  croak "db required"     unless $arg{db};
  croak "render required" unless $arg{render};
  return bless {db => $arg{db}, render => $arg{render}}, $class;
}

require Iczelia::Content::Pages;
require Iczelia::Content::Posts;
require Iczelia::Content::Dynamic;
require Iczelia::Content::Langs;
require Iczelia::Content::Media;
require Iczelia::Content::Activity;
require Iczelia::Content::Webring;
require Iczelia::Content::Settings;

1;
