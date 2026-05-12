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
use File::Temp ();

use_ok('Iczelia::Template');

my $tmp = File::Temp->newdir;
my $dir = "$tmp";

sub put {
  my ($f, $c) = @_;
  open my $fh, '>', "$dir/$f" or die $!;
  print $fh $c;
  close $fh;
}

my $t = Iczelia::Template->new(dirs => [$dir]);

# 1: simple interpolation + escape
put 'a.tpl' => 'hello {{ name }}!';
is $t->render('a.tpl', {name => 'world'}), 'hello world!',     'simple var';
is $t->render('a.tpl', {name => '<x>'}),   'hello &lt;x&gt;!', 'escaped';

# 2: raw
put 'b.tpl' => '{{{ name }}}';
is $t->render('b.tpl', {name => '<x>'}), '<x>', 'raw unescaped';

# 3: dotted access
put 'c.tpl' => 'hi {{ user.name }}';
is $t->render('c.tpl', {user => {name => 'kamila'}}), 'hi kamila', 'dotted';

# 4: if/else
put 'd.tpl' => '{% if x %}yes{% else %}no{% endif %}';
is $t->render('d.tpl', {x => 1}), 'yes', 'if true';
is $t->render('d.tpl', {x => 0}), 'no',  'if false';
is $t->render('d.tpl', {}), 'no', 'if missing';

# 5: for loop
put 'e.tpl' => '{% for x in xs %}<{{ x }}>{% endfor %}';
is $t->render('e.tpl', {xs => ['a', 'b', 'c']}), '<a><b><c>', 'for over array';
is $t->render('e.tpl', {xs => []}),              '',          'for empty';

# 6: function call
put 'f.tpl' => '{{ excerpt(s, 8) }}';
is $t->render('f.tpl', {s => 'hello world'}), 'hello...', 'excerpt';

# 7: extends + block
put 'parent.tpl' =>
  '<html><head><title>{% block title %}default{% endblock %}</title></head><body>{% block body %}{% endblock %}</body></html>';
put 'child.tpl' =>
  qq{{% extends "parent.tpl" %}{% block title %}{{ title }}{% endblock %}{% block body %}<p>{{ msg }}</p>{% endblock %}};
is $t->render('child.tpl', {title => 'Hi', msg => 'hello'}),
  '<html><head><title>Hi</title></head><body><p>hello</p></body></html>',
  'extends + blocks';

# 8: extends with default block content if not overridden
put 'child2.tpl' =>
  qq{{% extends "parent.tpl" %}{% block title %}only{% endblock %}};
is $t->render('child2.tpl', {}),
  '<html><head><title>only</title></head><body></body></html>',
  'default block kept';

# 9: include
put 'partial.tpl' => '[{{ x }}]';
put 'main.tpl'    => qq{a {% include "partial.tpl" %} b};
is $t->render('main.tpl', {x => 'Z'}), 'a [Z] b', 'include';

# 10: comment
put 'g.tpl' => 'a{# comment #}b';
is $t->render('g.tpl', {}), 'ab', 'comment stripped';

# 11: dotted on for-loop var
put 'h.tpl' => '{% for p in ps %}<{{ p.name }}>{% endfor %}';
is $t->render('h.tpl', {ps => [{name => 'A'}, {name => 'B'}]}),
  '<A><B>', 'for over hash list';

# 12: outer var visible inside loop
put 'i.tpl' => '{% for x in xs %}{{ prefix }}{{ x }}{% endfor %}';
is $t->render('i.tpl', {prefix => '* ', xs => ['a', 'b']}), '* a* b',
  'outer var in loop';

done_testing;
