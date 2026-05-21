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

use strict;
use warnings;
use Test::More;
use FindBin ();
use lib "$FindBin::Bin/../lib";

use Iczelia::UA;

sub p {Iczelia::UA::parse($_[0])}

# Desktop browsers.
my $chrome = p(
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    . '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
is($chrome->{browser}, 'Chrome',  'chrome browser');
is($chrome->{os},      'Windows', 'chrome os');
is($chrome->{device},  'desktop', 'chrome device');
is($chrome->{is_bot},  0,         'chrome not a bot');
is($chrome->{bot_ua},  undef,     'chrome stores no raw UA');

my $ff = p('Mozilla/5.0 (X11; Linux x86_64; rv:121.0) '
    . 'Gecko/20100101 Firefox/121.0');
is($ff->{browser}, 'Firefox', 'firefox browser');
is($ff->{os},      'Linux',   'firefox os');

my $safari = p(
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
    . '(KHTML, like Gecko) Version/17.1 Safari/605.1.15');
is($safari->{browser}, 'Safari', 'safari browser');
is($safari->{os},      'macOS',  'safari os');

my $edge = p(
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    . '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0');
is($edge->{browser}, 'Edge', 'edge wins over chrome');

# Mobile and tablet.
my $iphone = p(
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) '
    . 'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 '
    . 'Mobile/15E148 Safari/604.1');
is($iphone->{os},       'iOS',    'iphone os');
is($iphone->{device},   'mobile', 'iphone device');
is($iphone->{ua_class}, 'mobile', 'iphone class');

my $android = p('Mozilla/5.0 (Linux; Android 14; Pixel 8) '
    . 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 '
    . 'Mobile Safari/537.36');
is($android->{os},     'Android', 'android os beats linux');
is($android->{device}, 'mobile',  'android phone device');

my $ipad = p('Mozilla/5.0 (iPad; CPU OS 17_1 like Mac OS X) '
    . 'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 '
    . 'Mobile/15E148 Safari/604.1');
is($ipad->{device}, 'tablet', 'ipad is a tablet');

my $atab = p('Mozilla/5.0 (Linux; Android 13; SM-X700) '
    . 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 '
    . 'Safari/537.36');
is($atab->{device}, 'tablet', 'android without Mobile is a tablet');

# Bots: search, AI, libraries, generic.
for my $case (
  ['Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)'],
  ['Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)'],
  ['Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)'],
  ['curl/8.4.0'],
  ['python-requests/2.31.0'],
  ['Go-http-client/2.0'],
  ['SomethingNew Crawler/3.0 (+http://example.com/about)'],
  )
{
  my $r = p($case->[0]);
  is($r->{is_bot},   1,     "bot detected: $case->[0]");
  is($r->{device},   'bot', "bot device: $case->[0]");
  is($r->{browser},  undef, "bot has no browser: $case->[0]");
  ok(defined $r->{bot_ua} && length $r->{bot_ua}, "bot UA retained: $case->[0]");
}

my $headless = p('Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
    . '(KHTML, like Gecko) HeadlessChrome/120.0.0.0 Safari/537.36');
is($headless->{is_bot}, 1, 'headless chrome is a bot');

# Empty UA stays "other", not a bot.
my $empty = p('');
is($empty->{is_bot},   0,       'empty UA not a bot');
is($empty->{ua_class}, 'other', 'empty UA class');
is($empty->{device},   'other', 'empty UA device');

# Raw bot UA is cleaned and length-capped.
my $long = p('EvilCrawler/1.0 ' . ('x' x 500));
ok(length($long->{bot_ua}) <= 300, 'bot UA truncated to 300 chars');

done_testing;
