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

# The preview endpoint runs Markup::render with math substitution. We
# don't spin up the HTTP server here; just verify the pipeline produces
# the expected HTML for the editor preview pane.
use Iczelia::Markup;

my ($html, $math) = Iczelia::Markup::render("# title\n\nhello *world*");
like($html, qr/<h1[^>]*>title/i, 'heading rendered');
like($html, qr/<em>world<\/em>/, 'emphasis rendered');

# Inline math is extracted as a placeholder for later substitution.
my ($html2, $math2) = Iczelia::Markup::render('inline $a^2$ math');
like($html2, qr/__MATH\d+__/, 'math placeholder injected');
is(scalar(@$math2), 1,     'one math fragment captured');
is($math2->[0][1],  'a^2', 'latex source captured');

# Fenced code blocks go through the highlighter (no language -> plain).
my ($html3) = Iczelia::Markup::render("\`\`\`c\nint x = 1;\n\`\`\`");
like(
  $html3,
  qr/<pre[^>]*class="hl[^"]*lang-c"/,
  'C code block tagged with lang-c'
);
like($html3, qr/<span class="hl-typ">int<\/span>/, 'C type highlighted');

done_testing;
