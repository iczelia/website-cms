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

package Iczelia::Template;
use strict;
use warnings;
use File::Spec    ();
use Carp          qw(croak);
use Iczelia::Util ();

# Template DSL:
#   {{ x }} / {{{ x }}}        escaped / raw expression
#   {% if/elsif/else/endif %} | {% for x in list %}{% endfor %}
#   {% include "p.tpl" %} | {% extends "p.tpl" %} + {% block n %} | {# .. #}
# Expressions are barewords, dotted accesses, or %FUNCS calls; no Perl.
# Compiles once per file; cache mtime-checks each lookup.

my %FUNCS = (
  fmt_date  => sub {Iczelia::Util::fmt_date($_[0])},
  fmt_iso   => sub {Iczelia::Util::fmt_iso($_[0])},
  fmt_ago   => sub {Iczelia::Util::fmt_ago($_[0])},
  excerpt   => sub {Iczelia::Util::excerpt($_[0], $_[1])},
  count     => sub {ref $_[0] eq 'ARRAY' ? scalar @{$_[0]}    : 0},
  reverse   => sub {ref $_[0] eq 'ARRAY' ? [reverse @{$_[0]}] : ''},
  upper     => sub {defined $_[0]        ? uc $_[0]           : ''},
  lower     => sub {defined $_[0]        ? lc $_[0]           : ''},
  raw       => sub {defined $_[0]        ? $_[0]              : ''},
  esc_attr  => sub {Iczelia::Util::escape_attr($_[0])},
  urlencode => sub {Iczelia::Util::escape_url($_[0])},
);

sub new {
  my ($class, %arg) = @_;
  return bless {
    dirs   => $arg{dirs} || [],
    cache  => {},
    mtimes => {},
  }, $class;
}

sub render {
  my ($self, $name, $vars) = @_;
  my $sub = $self->_compile($name);
  return $sub->($self, $vars || {});
}

sub _find {
  my ($self, $name) = @_;
  for my $d (@{$self->{dirs}}) {
    my $p = File::Spec->catfile($d, $name);
    return $p if -r $p;
  }
  croak "template not found: $name (dirs: @{ $self->{dirs} })";
}

sub _read {
  my ($self, $name) = @_;
  my $p = $self->_find($name);

  # Decode as UTF-8 so multibyte template literals stay wide chars.
  open my $fh, '<:encoding(UTF-8)', $p or croak "open $p: $!";
  local $/;
  my $src = <$fh>;
  close $fh;
  return $src;
}

sub _compile {
  my ($self, $name) = @_;

  my $path  = $self->_find($name);
  my $mtime = (stat $path)[9];
  if ($self->{cache}{$name} && ($self->{mtimes}{$name} || 0) == $mtime) {
    return $self->{cache}{$name};
  }

  my $src = $self->_read($name);
  $src = $self->_resolve_extends($src);
  $src = $self->_resolve_includes($src);

  my $code = $self->_compile_text($src, $name);
  my $sub  = eval $code;
  if ($@) {
    my $err = $@;
    die "template $name: compile error: $err\n--- generated code ---\n$code\n";
  }

  $self->{cache}{$name}  = $sub;
  $self->{mtimes}{$name} = $mtime;
  return $sub;
}

sub _resolve_extends {
  my ($self, $src) = @_;
  return $src unless $src =~ /\A\s*\{\%\s*extends\s+"([^"]+)"\s*\%\}\s*/s;
  my $parent_name = $1;
  my $rest        = substr($src, $+[0]);

  my %blocks;
  while ($rest =~ /\{\%\s*block\s+(\w+)\s*\%\}(.*?)\{\%\s*endblock\s*\%\}/sg) {
    $blocks{$1} = $2;
  }

  my $parent = $self->_read($parent_name);
  $parent = $self->_resolve_extends($parent);

  $parent =~ s{\{\%\s*block\s+(\w+)\s*\%\}(.*?)\{\%\s*endblock\s*\%\}}{
        exists $blocks{$1} ? $blocks{$1} : $2
    }gse;

  return $parent;
}

sub _resolve_includes {
  my ($self, $src) = @_;
  my $iter = 0;
  while ($src =~ /\{\%\s*include\s+"([^"]+)"\s*\%\}/) {
    croak "template: include recursion (>16 levels)" if ++$iter > 16;
    my $name = $1;
    my $sub  = $self->_read($name);
    $sub = $self->_resolve_extends($sub);
    $src =~ s/\{\%\s*include\s+"\Q$name\E"\s*\%\}/$sub/g;
  }
  return $src;
}

sub _compile_text {
  my ($self, $src, $name) = @_;

  $src =~ s/\{\#.*?\#\}//gs;

  # Drop stray block markers from a parent-less extends.
  $src =~ s/\{\%\s*block\s+\w+\s*\%\}//g;
  $src =~ s/\{\%\s*endblock\s*\%\}//g;

  my @code = (
    "sub {",
    "  my (\$tpl, \$v) = \@_;",
    "  my \@ctx = (\$v);",
    "  my \$out = '';",
  );

  pos($src) = 0;
  while ($src =~ /\G(.*?)(\{\{\{|\{\{|\{\%)/cgs) {
    my $literal = $1;
    my $tag     = $2;
    push @code, '  $out .= ' . _q($literal) . ';' if length $literal;

    if ($tag eq '{{{') {
      $src =~ /\G(.*?)\}\}\}/cgs or croak "template $name: unclosed {{{";
      push @code, '  $out .= Iczelia::Template::_str(' . _expr($1) . ');';
    }
    elsif ($tag eq '{{') {
      $src =~ /\G(.*?)\}\}/cgs or croak "template $name: unclosed {{";
      push @code,
        '  $out .= Iczelia::Util::escape_html(Iczelia::Template::_str('
        . _expr($1) . '));';
    }
    elsif ($tag eq '{%') {
      $src =~ /\G\s*(.*?)\s*\%\}/cgs or croak "template $name: unclosed {%";
      push @code, _stmt($1, $name);
    }
  }

  my $tail = substr($src, pos($src) // 0);
  push @code, '  $out .= ' . _q($tail) . ';' if length $tail;

  push @code, "  return \$out;", "}";
  return join("\n", @code);
}

sub _q {
  my $s = shift;
  $s =~ s/\\/\\\\/g;
  $s =~ s/'/\\'/g;
  return "'$s'";
}

sub _expr {
  my $expr = shift;
  $expr =~ s/^\s+//;
  $expr =~ s/\s+$//;

  if ($expr =~ /^(\w+)\(\s*(.*?)\s*\)$/s) {
    my ($fn, $args) = ($1, $2);
    croak "template: unknown function $fn"
      unless exists $FUNCS{$fn};

    # The DSL has no nested commas, so a flat split is enough.
    my @args    = length $args ? split(/\s*,\s*/, $args) : ();
    my $argcode = join ',', map {_expr($_)} @args;
    return "Iczelia::Template::_call('$fn', $argcode)";
  }

  if ($expr =~ /^"([^"]*)"$/) {
    return _q($1);
  }
  if ($expr =~ /^-?\d+$/) {
    return $expr;
  }
  if ($expr =~ /^[\w]+(?:\.[\w]+)*$/) {
    my @parts = split /\./, $expr;
    my $first = shift @parts;
    my $code  = "Iczelia::Template::_lookup(\\\@ctx, '$first')";
    $code = "Iczelia::Template::_dot($code, '$_')" for @parts;
    return $code;
  }

  croak "template: bad expression: '$expr'";
}

sub _stmt {
  my ($stmt, $tname) = @_;
  if ($stmt =~ /^if\s+(.+)$/s) {
    return '  if (Iczelia::Template::_truthy(' . _expr($1) . ")) {";
  }
  if ($stmt =~ /^elsif\s+(.+)$/s) {
    return '  } elsif (Iczelia::Template::_truthy(' . _expr($1) . ")) {";
  }
  if ($stmt =~ /^else$/)  {return "  } else {"}
  if ($stmt =~ /^endif$/) {return "  }"}
  if ($stmt =~ /^for\s+(\w+)\s+in\s+(.+)$/s) {
    my ($var, $list) = ($1, $2);
    my $listc = _expr($list);
    return "  for my \$tpl_loop_$var (Iczelia::Template::_iter($listc)) {\n"
      . "    push \@ctx, { '$var' => \$tpl_loop_$var };";
  }
  if ($stmt =~ /^endfor$/) {return "    pop \@ctx;\n  }"}
  croak "template $tname: unknown statement: $stmt";
}

sub _str {
  my $v = shift;
  return '' unless defined $v;
  return $v if !ref $v;
  return '' if ref $v eq 'HASH';
  return '' if ref $v eq 'ARRAY';
  return "$v";
}

sub _truthy {
  my $v = shift;
  return 0 unless defined $v;
  return 0                    if !ref $v && $v eq '';
  return 0                    if !ref $v && $v eq '0';
  return scalar @$v > 0       if ref $v eq 'ARRAY';
  return scalar(keys %$v) > 0 if ref $v eq 'HASH';
  return $v ? 1 : 0;
}

sub _iter {
  my $v = shift;
  return () unless defined $v;
  return @$v      if ref $v eq 'ARRAY';
  return keys %$v if ref $v eq 'HASH';
  return ($v);
}

sub _lookup {
  my ($ctx, $name) = @_;
  for my $i (reverse 0 .. $#$ctx) {
    my $h = $ctx->[$i];
    return $h->{$name} if ref $h eq 'HASH' && exists $h->{$name};
  }
  return undef;
}

sub _dot {
  my ($v, $key) = @_;
  return undef unless defined $v;
  if (ref $v eq 'HASH') {
    return $v->{$key};
  }
  elsif (ref $v eq 'ARRAY') {
    return $v->[$key] if $key =~ /^-?\d+$/;
    return scalar @$v if $key eq 'length' || $key eq 'count';
  }
  return undef;
}

sub _call {
  my ($fn, @args) = @_;
  return $FUNCS{$fn}->(@args);
}

1;
