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

package Iczelia::Handlers::Admin::Forms;
use strict;
use warnings;
use Exporter      qw(import);
use Iczelia::Util qw(escape_html);

our @EXPORT_OK = qw(
  field_for_form kvtable_html kvtable_rows_from_params
  simple_form_render
);

# Schema-field input renderer. Maps a schema field record to a hashref
# with pre-rendered input_html, ready to drop into admin_edit_page.tpl.
sub field_for_form {
  my ($f, $value) = @_;
  my $kind   = $f->{kind};
  my $name   = $f->{name};
  my $name_a = escape_html($name);
  my $rec    = {
    name  => $name,
    kind  => $kind,
    label => $f->{label} // $name,
    help  => $f->{help},
  };

  if ($kind eq 'markdown') {
    my $v = escape_html(defined $value ? $value : '');
    $rec->{input_html} =
      qq{<textarea class="cm-md" name="$name_a" rows="10">$v</textarea>};
  }
  elsif ($kind eq 'markdown_inline') {
    my $v = escape_html(defined $value ? $value : '');
    $rec->{input_html} = qq{<input type="text" name="$name_a" value="$v">};
  }
  elsif ($kind eq 'text') {
    my $v = escape_html(defined $value ? $value : '');
    my $max =
      defined $f->{max} ? ' maxlength="' . escape_html($f->{max}) . '"' : '';
    $rec->{input_html} = qq{<input type="text" name="$name_a" value="$v"$max>};
  }
  elsif ($kind eq 'int') {
    my $v   = defined $value    ? (0 + $value) : ($f->{default} // 0);
    my $min = defined $f->{min} ? ' min="' . escape_html($f->{min}) . '"' : '';
    my $max = defined $f->{max} ? ' max="' . escape_html($f->{max}) . '"' : '';
    $rec->{input_html} =
      qq{<input type="number" name="$name_a" value="$v"$min$max>};
  }
  elsif ($kind eq 'bool') {
    my $checked = $value ? ' checked' : '';
    $rec->{input_html} =
      qq{<label><input type="checkbox" name="$name_a" value="1"$checked> on</label>};
  }
  elsif ($kind eq 'kv-table') {
    $rec->{input_html} = kvtable_html($f, $value || []);
  }
  else {
    $rec->{input_html} =
      '<em>unsupported field kind: ' . escape_html($kind) . '</em>';
  }
  return $rec;
}

sub kvtable_html {
  my ($f, $rows) = @_;
  my @bits;
  my $field_a = escape_html($f->{name});
  push @bits, qq{<table class="cms-kvtable" data-field="$field_a">};
  push @bits, '<thead><tr>';
  push @bits, '<th class="cms-kvtable-handle"></th>';
  for my $c (@{$f->{columns}}) {
    my $w =
      defined $c->{width}
      ? ' style="width: ' . escape_html($c->{width}) . '"'
      : '';
    push @bits, '<th' . $w . '>' . escape_html($c->{label}) . '</th>';
  }
  push @bits, '<th class="cms-kvtable-actions"></th></tr></thead><tbody>';
  my $idx = 0;
  for my $r (@$rows) {
    push @bits, '<tr>';
    push @bits, '<td class="cms-kvtable-handle"><span class="cms-drag-handle" draggable="true">&#x283F;</span></td>';
    for my $c (@{$f->{columns}}) {
      my $v  = escape_html($r->{$c->{name}} // '');
      my $nm = escape_html($f->{name} . "__row${idx}__" . $c->{name});
      push @bits, qq{<td><input type="text" name="$nm" value="$v"></td>};
    }
    push @bits,
      '<td class="cms-kvtable-actions"><button type="button" class="cms-row-del">&times;</button></td>';
    push @bits, '</tr>';
    $idx++;
  }

  # Trailing empty row so users can extend without JS.
  push @bits, '<tr>';
  push @bits, '<td class="cms-kvtable-handle"><span class="cms-drag-handle" draggable="true">&#x283F;</span></td>';
  for my $c (@{$f->{columns}}) {
    my $nm = escape_html($f->{name} . "__row${idx}__" . $c->{name});
    push @bits, qq{<td><input type="text" name="$nm" value=""></td>};
  }
  push @bits, '<td></td></tr>';
  push @bits, '</tbody></table>';
  push @bits,
    qq{<p class="cms-kvtable-add"><button type="button" data-field="$field_a" class="cms-row-add">+ add row</button></p>};
  return join '', @bits;
}

# Render an inputs-only form body inside the admin chrome (the chrome
# wraps it in <form>). Used by Activity, Webring, Settings.
sub simple_form_render {
  my ($ctx, $req, %arg) = @_;
  my $vars = Iczelia::Handlers::Admin::admin_vars(
    $ctx, $req, title => $arg{title});
  $vars->{form_action} = $arg{action};
  $vars->{form_csrf}   = $arg{csrf};
  $vars->{form_body}   = $arg{body};
  return $ctx->template->render('views/admin_simple_form.tpl', $vars);
}

sub kvtable_rows_from_params {
  my ($params) = @_;
  my %by_row;
  for my $k (keys %$params) {
    if ($k =~ /^rows__row(\d+)__(\w+)$/) {
      $by_row{$1}{$2} = $params->{$k};
    }
  }
  return map {$by_row{$_}} sort {$a <=> $b} keys %by_row;
}

1;
