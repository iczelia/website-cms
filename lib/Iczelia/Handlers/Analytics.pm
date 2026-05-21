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

package Iczelia::Handlers::Analytics;
use strict;
use warnings;
use Iczelia::HTTP            ();
use Iczelia::Analytics       ();
use Iczelia::Handlers::Admin ();

use constant ANALYTICS_RAW_LIMIT => 200;

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = \&Iczelia::Handlers::Admin::gate;
  $router->get('/admin/analytics/', sub {$gate->(\&_dashboard, $ctx, $_[0])});
  $router->get('/admin/analytics/data.json',
    sub {$gate->(\&_data_json, $ctx, $_[0])});
  $router->get('/admin/analytics/raw', sub {$gate->(\&_raw, $ctx, $_[0])});
}

# The dashboard itself is rendered client-side from /data.json; the
# template only ships a mount point.
sub _dashboard {
  my ($ctx, $req) = @_;
  return Iczelia::Handlers::Admin::render_admin($ctx, $req,
    'admin_analytics.tpl', title => 'analytics');
}

sub _params {
  my ($req) = @_;
  my $range = $req->{qparams}{range} // '7d';
  $range = '7d' unless $range =~ /^(?:7d|30d|all)$/;
  my $bots = ($req->{qparams}{bots} // '') eq 'hide' ? 'hide' : 'show';
  return ($range, $bots);
}

sub _data_json {
  my ($ctx, $req) = @_;
  my ($range, $bots) = _params($req);
  my $data = Iczelia::Analytics::dashboard_data(
    $ctx->db,
    range => $range,
    bots  => $bots,
  );
  $data->{generated_at} = time;
  return Iczelia::HTTP::json($data);
}

sub _raw {
  my ($ctx, $req) = @_;
  my $rows = $ctx->db->all(
    q{SELECT id, ts, path, status, method, visitor_hash, referer_host,
             ua_class, browser, os, device, bot_ua
        FROM analytics_events ORDER BY id DESC LIMIT } . ANALYTICS_RAW_LIMIT
  );
  for my $r (@$rows) {
    my @t = gmtime($r->{ts});
    $r->{ts_fmt} = sprintf '%04d-%02d-%02d %02d:%02d:%02d',
      $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
    $r->{ua_detail} =
        $r->{bot_ua}                ? $r->{bot_ua}
      : ($r->{browser} || $r->{os}) ? join(' / ',
        grep {defined && length} $r->{browser}, $r->{os})
      :                             '';
  }
  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_analytics_raw.tpl',
    title  => 'analytics raw',
    events => $rows,
  );
}

1;
