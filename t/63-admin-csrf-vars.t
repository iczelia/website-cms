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

# admin_vars() owns the csrf hash handed to every admin template. The
# layout reads csrf.upload into <meta name="cms-upload-csrf">, which the
# chunked uploader sends to /admin/upload/init -- so csrf.upload must
# ALWAYS be present, and a view's own tokens (merged via csrf_extra) must
# never knock it (or each other) out. This regression guards the bug
# where the backup view passed csrf wholesale, blanked csrf.upload, and
# made every large import fail with "Bad Request: csrf".

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";

use Iczelia::DB;
use Iczelia::Auth;
use Iczelia::Context;
use Iczelia::Handlers::Admin;

my $tmp = File::Temp->newdir;
my $db  = Iczelia::DB->connect("$tmp/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");

my $auth = Iczelia::Auth->new(db => $db, cookie_secret => 'e' x 64);
my $ctx  = Iczelia::Context->new(db => $db, auth => $auth);
my $req  = {auth_sid => 'sid1'};

# 1. Baseline: the chunked-uploader token is always present and correct.
my $v = Iczelia::Handlers::Admin::admin_vars($ctx, $req, title => 'x');
ok(length($v->{csrf}{upload} // ''), 'csrf.upload present');
is($v->{csrf}{upload}, $auth->csrf_token('sid1', 'upload'),
  'csrf.upload is the real upload token');

# 2. csrf_extra merges the view's tokens WITHOUT dropping the built-ins
#    (the exact shape the backup view needs).
my $imp = $auth->csrf_token('sid1', 'backup:import');
my $v2  = Iczelia::Handlers::Admin::admin_vars(
  $ctx, $req,
  title      => 'backup / wipe',
  csrf_extra => {
    export => $auth->csrf_token('sid1', 'backup:export'),
    import => $imp,
    wipe   => $auth->csrf_token('sid1', 'backup:wipe'),
  },
);
is($v2->{csrf}{import}, $imp, 'csrf_extra: backup:import token present');
ok(length($v2->{csrf}{upload} // ''),
  'csrf_extra does not drop csrf.upload (the import regression)');

# 3. Defensive: a stray top-level csrf in %extra cannot clobber the
#    computed hash. upload survives; the bogus value is ignored.
my $v3 = Iczelia::Handlers::Admin::admin_vars(
  $ctx, $req,
  title => 'x',
  csrf  => {import => 'ZZZ'},
);
ok(length($v3->{csrf}{upload} // ''),
  'stray top-level csrf does not blank csrf.upload');
isnt($v3->{csrf}{import}, 'ZZZ', 'stray top-level csrf is ignored, not merged');

# 4. Framework keys are authoritative even if passed as extras.
my $v4 = Iczelia::Handlers::Admin::admin_vars(
  $ctx, $req,
  title     => 'x',
  csrf_form => 'real',
);
is($v4->{csrf_form}, 'real', 'csrf_form passes through');

done_testing;
