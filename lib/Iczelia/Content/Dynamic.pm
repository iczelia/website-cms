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

# Iczelia::Content fragment. Full package layout in Content.pm.
# Provides: validate_dynamic_route, list_dynamic_pages, get_dynamic_page,
#   get_dynamic_page_by_route, create_dynamic_page, update_dynamic_page,
#   delete_dynamic_page, _validate_template.
# Reads $self slots: db, render.

# Reserved-route policy for admin-defined dynamic pages.
#  - TREES: prefix off-limits, including any nested path.
#  - EXACT: only this exact path is taken; nested paths are still allowed.
#  - PREFIXES: any path that begins with this string.
my @RESERVED_TREES = (
  '/admin/',  '/blog/',  '/journal/', '/posts/',
  '/media/',  '/api/',   '/search/',  '/vendor/',
  '/assets-', '/fonts/', '/webring/', '/guestbook/',
  '/updates/',
);
my @RESERVED_EXACT = (
  '/about/',      '/cv/',        '/healthz',   '/login',
  '/logout',      '/feed.xml',   '/index.xml', '/rss.xml',
  '/sitemap.xml', '/robots.txt', '/pub.pgp',   '/favicon.ico',
);
my @RESERVED_PREFIXES = ('/cms.', '/style.', '/about.compat',);

sub validate_dynamic_route {
  my ($route) = @_;
  return (undef, 'route required')
    unless defined $route && length $route;
  return (undef, 'invalid route')
    unless $route =~ m{^/(?:[a-z0-9][a-z0-9-]*/){1,4}$};
  for my $p (@RESERVED_TREES) {
    return (undef, "reserved tree: $p")
      if index($route, $p) == 0;
  }
  for my $e (@RESERVED_EXACT) {
    return (undef, "reserved route: $e") if $route eq $e;
  }
  for my $p (@RESERVED_PREFIXES) {
    return (undef, "reserved prefix: $p")
      if index($route, $p) == 0;
  }
  return ($route, undef);
}

# Template name becomes a path component (views/<template>.tpl). Strict
# allowlist prevents traversal or injection.
sub _validate_template {
  my ($t) = @_;
  return 'generic' unless defined $t && length $t;
  return undef     unless $t =~ /^[a-z][a-z0-9_-]{0,40}$/;
  return $t;
}

sub list_dynamic_pages {
  my ($self) = @_;
  return $self->{db}->all(
    'SELECT id, route, title, template, updated_at
           FROM dynamic_pages ORDER BY route'
  );
}

sub get_dynamic_page {
  my ($self, $id) = @_;
  return $self->{db}->row('SELECT * FROM dynamic_pages WHERE id=?', $id);
}

sub get_dynamic_page_by_route {
  my ($self, $route) = @_;
  return $self->{db}->row('SELECT * FROM dynamic_pages WHERE route=?', $route);
}

sub create_dynamic_page {
  my ($self,  $rec) = @_;
  my ($route, $err) = validate_dynamic_route($rec->{route});
  return (undef, $err) if $err;
  return (undef, 'title required')
    unless defined $rec->{title} && length $rec->{title};
  my $tpl = _validate_template($rec->{template});
  return (undef, 'invalid template') unless defined $tpl;
  return (undef, 'route already exists')
    if $self->{db}->one('SELECT 1 FROM dynamic_pages WHERE route=?', $route);
  $self->{db}->do_(
    q{
        INSERT INTO dynamic_pages(route, title, template, data, updated_at)
        VALUES(?,?,?,?, strftime('%s','now'))},
    $route, $rec->{title}, $tpl, $rec->{data} // '{}'
  );
  if (my $r = $self->{render}) {
    $r->invalidate_route($_) for $route, '/sitemap.xml';
  }
  return ($self->{db}->last_id, undef);
}

sub update_dynamic_page {
  my ($self, $id, $rec) = @_;
  my $cur = $self->get_dynamic_page($id)
    or return (undef, 'not found');
  my ($route, $err) =
    validate_dynamic_route($rec->{route} // $cur->{route});
  return (undef, $err) if $err;
  if ( $route ne $cur->{route}
    && $self->{db}
    ->one('SELECT 1 FROM dynamic_pages WHERE route=? AND id<>?', $route, $id))
  {
    return (undef, 'route already exists');
  }
  my $tpl = _validate_template($rec->{template} // $cur->{template});
  return (undef, 'invalid template') unless defined $tpl;
  $self->{db}->do_(
    q{
        UPDATE dynamic_pages
           SET route=?, title=?, template=?, data=?,
               rendered_html=NULL,
               updated_at=strftime('%s','now')
         WHERE id=?},
    $route, $rec->{title} // $cur->{title}, $tpl,
    $rec->{data} // $cur->{data}, $id
  );
  if (my $r = $self->{render}) {
    $r->invalidate_route($_) for $cur->{route}, $route, '/sitemap.xml';
  }
  return ($id, undef);
}

sub delete_dynamic_page {
  my ($self, $id) = @_;
  my $cur = $self->get_dynamic_page($id) or return;
  $self->{db}->do_('DELETE FROM dynamic_pages WHERE id=?', $id);
  if (my $r = $self->{render}) {
    $r->invalidate_route($_) for $cur->{route}, '/sitemap.xml';
  }
}

1;
