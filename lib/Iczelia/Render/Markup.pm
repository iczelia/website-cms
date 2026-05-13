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

package Iczelia::Render;
use strict;
use warnings;
use Iczelia::Markup ();
use Iczelia::Util   ();

# Iczelia::Render fragment. Full package layout in Render.pm.
# Provides: _md, _meta_desc (and helper _para_with_text),
#   _cook_page_data, substitute_math.
# Reads $self slots: tex (via substitute_math).
# Calls cross-file helpers: none.

my $INTRO_HEADING_RE = qr{
  \A \s* (?: \d+ [.)]? \s+ )?
  (?: intro(?:duction)? | preliminaries | overview | background
    | abstract | motivation | prologue | preface | context | tl;?dr )
  \b
}xi;

sub _para_with_text {
  my ($html) = @_;
  return undef unless defined $html;
  while ($html =~ m{<p\b[^>]*>(.*?)</p\s*>}gis) {
    my $c = $1;
    (my $bare = $c) =~ s/<[^>]+>//g;
    $bare =~ s/&\#?\w+;//g;
    return $c if $bare =~ /\S/;
  }
  return undef;
}

sub _meta_desc {
  my ($html, $n) = @_;
  $n ||= 160;
  return '' unless defined $html && length $html;

  my $from = 0;
  while ($html =~ m{<h[1-6]\b[^>]*>(.*?)</h[1-6]\s*>}gis) {
    (my $ht = $1) =~ s/<[^>]+>//g;
    $ht =~ s/&\#?\w+;/ /g;
    $ht =~ s/^\s+//;
    $ht =~ s/\s+/ /g;
    if ($ht =~ $INTRO_HEADING_RE) {$from = pos($html); last}
  }
  my $t = ($from ? _para_with_text(substr($html, $from)) : undef)
       // _para_with_text($html)
       // $html;

  $t =~ s{<[^>]+>}{ }g;
  $t =~ s/&nbsp;/ /g;
  $t =~ s/&amp;/&/g;
  $t =~ s/&lt;/</g;
  $t =~ s/&gt;/>/g;
  $t =~ s/&quot;/"/g;
  $t =~ s/&#0*39;|&apos;/'/g;
  $t =~ s/&#x?[0-9A-Fa-f]+;/ /g;
  $t =~ s/&[A-Za-z][A-Za-z0-9]*;/ /g;
  $t =~ s/\s+/ /g;
  $t =~ s/ +([.,;:!?)\]}\xbb\x{2026}"'])/$1/g;
  $t =~ s/([(\[{\xab]) +/$1/g;
  $t =~ s/^\s+//;
  $t =~ s/\s+$//;
  if (length $t > $n) {
    $t = substr($t, 0, $n);
    $t =~ s/\s+\S*$//;
    $t .= '...';
  }
  return $t;
}

sub _cook_page_data {
  my ($self, $template, $data) = @_;
  my %out = %$data;

  for my $f (
    qw(
    intro body
    reach_out employment talks links hardware setup patreon misc qr
    experience education works
    )
    )
  {
    if (defined $data->{$f}) {
      $out{"${f}_html"} = $self->_md($data->{$f});
    }
  }

  if (ref $data->{vitals} eq 'ARRAY') {
    $out{vitals} = [
      map {
        {%$_, value_html => $self->_md($_->{value}, inline => 1)}
      } @{$data->{vitals}}
    ];
  }
  if (ref $data->{elsewhere} eq 'ARRAY') {
    $out{elsewhere} = [
      map {
        {%$_, label_html => $self->_md($_->{label}, inline => 1)}
      } @{$data->{elsewhere}}
    ];
  }
  return \%out;
}

sub _md {
  my ($self, $src, %opt) = @_;
  return '' unless defined $src && length $src;
  $src = Iczelia::Util::to_utf8($src);
  if ($opt{inline}) {
    my $html = Iczelia::Markup::render_inline($src);
    return $self->substitute_math($html, []);
  }
  my ($html, $math) = Iczelia::Markup::render($src);
  return $self->substitute_math($html, $math);
}

# Replace __MATH<n>__ placeholders with rendered <img>s when Tex is wired.
sub substitute_math {
  my ($self, $html, $math) = @_;

  if (!$self->{tex}) {
    $html =~ s{__MATH\d+__}{}g;
    return $html;
  }
  $html =~ s{__MATH(\d+)__}{
        my $entry = $math->[$1];
        $entry ? $self->{tex}->render(@$entry) : '';
    }ge;
  return $html;
}

1;
