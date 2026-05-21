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

package Iczelia::UA;
use strict;
use warnings;

# Humans keep only a derived browser/os/device; bots keep the raw
# (cleaned) UA. A raw human UA is never returned for storage.

# First matching pattern wins; the label is only used for detection,
# the stored bot_ua is the raw string.
my @BOTS = (
  [qr{googlebot|google-inspectiontool|storebot-google}i => 'Googlebot'],
  [qr{adsbot-google|mediapartners-google|apis-google}i  => 'Google'],
  [qr{google-extended|google-cloudvertexbot}i           => 'Google AI'],
  [qr{feedfetcher-google}i                              => 'Googlebot'],
  [qr{bingbot|bingpreview|adidxbot|msnbot}i             => 'Bingbot'],
  [qr{\bslurp\b}i                                       => 'Yahoo Slurp'],
  [qr{duckduckbot|duckduckgo-favicons}i                 => 'DuckDuckBot'],
  [qr{yandex(?:bot|images|video|media|webmaster)}i      => 'YandexBot'],
  [qr{baiduspider}i                                     => 'Baiduspider'],
  [qr{sogou\s}i                                         => 'Sogou'],
  [qr{seznambot}i                                       => 'SeznamBot'],
  [qr{petalbot}i                                        => 'PetalBot'],
  [qr{exabot|exalead}i                                  => 'Exabot'],
  [qr{applebot}i                                        => 'Applebot'],
  [qr{gptbot}i                                          => 'GPTBot'],
  [qr{oai-searchbot}i                                   => 'OAI-SearchBot'],
  [qr{chatgpt-user}i                                    => 'ChatGPT-User'],
  [qr{claudebot}i                                       => 'ClaudeBot'],
  [qr{claude-web}i                                      => 'Claude-Web'],
  [qr{claude-user}i                                     => 'Claude-User'],
  [qr{claude-searchbot}i                                => 'Claude-SearchBot'],
  [qr{anthropic-ai}i                                    => 'anthropic-ai'],
  [qr{\bccbot\b}i                                       => 'CCBot'],
  [qr{perplexitybot}i                                   => 'PerplexityBot'],
  [qr{perplexity-user}i                                 => 'Perplexity-User'],
  [qr{bytespider}i                                      => 'Bytespider'],
  [qr{amazonbot}i                                       => 'Amazonbot'],
  [qr{meta-externalagent|meta-externalfetcher}i         => 'Meta'],
  [qr{facebookbot}i                                     => 'FacebookBot'],
  [qr{imagesiftbot}i                                    => 'ImagesiftBot'],
  [qr{diffbot}i                                         => 'Diffbot'],
  [qr{cohere-ai|cohere-training}i                       => 'cohere-ai'],
  [qr{\bai2bot\b}i                                      => 'AI2Bot'],
  [qr{timpibot}i                                        => 'Timpibot'],
  [qr{\bomgili\b|webzio}i                               => 'Omgili'],
  [qr{\byoubot\b}i                                      => 'YouBot'],
  [qr{ahrefsbot}i                                       => 'AhrefsBot'],
  [qr{semrushbot}i                                      => 'SemrushBot'],
  [qr{mj12bot}i                                         => 'MJ12bot'],
  [qr{\bdotbot\b}i                                      => 'DotBot'],
  [qr{dataforseobot}i                                   => 'DataForSeoBot'],
  [qr{blexbot}i                                         => 'BLEXBot'],
  [qr{barkrowler}i                                      => 'Barkrowler'],
  [qr{serpstatbot}i                                     => 'serpstatbot'],
  [qr{screaming\s?frog}i                                => 'Screaming Frog'],
  [qr{facebookexternalhit}i  => 'facebookexternalhit'],
  [qr{twitterbot}i           => 'Twitterbot'],
  [qr{linkedinbot}i          => 'LinkedInBot'],
  [qr{slackbot|slack-imgproxy}i => 'Slackbot'],
  [qr{discordbot}i           => 'Discordbot'],
  [qr{telegrambot}i          => 'TelegramBot'],
  [qr{whatsapp}i             => 'WhatsApp'],
  [qr{pinterest(?:bot|/)}i   => 'Pinterestbot'],
  [qr{redditbot}i            => 'redditbot'],
  [qr{embedly}i              => 'Embedly'],
  [qr{skypeuripreview}i      => 'Skype'],
  [qr{uptimerobot}i          => 'UptimeRobot'],
  [qr{pingdom}i              => 'Pingdom'],
  [qr{statuscake}i           => 'StatusCake'],
  [qr{site24x7}i             => 'Site24x7'],
  [qr{datadog}i              => 'Datadog'],
  [qr{newrelicpinger}i       => 'New Relic'],
  [qr{gtmetrix}i             => 'GTmetrix'],
  [qr{chrome-lighthouse|google\s?pagespeed}i => 'Lighthouse'],
  [qr{headlesschrome}i       => 'HeadlessChrome'],
  [qr{phantomjs}i            => 'PhantomJS'],
  [qr{playwright}i           => 'Playwright'],
  [qr{puppeteer}i            => 'Puppeteer'],
  [qr{selenium}i             => 'Selenium'],
  [qr{scrapy}i               => 'Scrapy'],
  [qr{python-requests}i      => 'python-requests'],
  [qr{python-httpx|\bhttpx\b}i => 'python-httpx'],
  [qr{python-urllib|\burllib\b}i => 'python-urllib'],
  [qr{aiohttp}i              => 'aiohttp'],
  [qr{\bgo-http-client}i     => 'Go-http-client'],
  [qr{okhttp}i               => 'OkHttp'],
  [qr{apache-httpclient|jakarta\scommons-httpclient}i => 'Apache-HttpClient'],
  [qr{\bjava/\d}i            => 'Java'],
  [qr{\baxios/}i             => 'axios'],
  [qr{node-fetch|\bundici\b}i => 'node-fetch'],
  [qr{\bcurl/}i              => 'curl'],
  [qr{\bwget\b}i             => 'Wget'],
  [qr{libwww-perl|lwp::simple}i => 'libwww-perl'],
  [qr{winhttp}i              => 'WinHTTP'],
  [qr{postmanruntime}i       => 'Postman'],
  [qr{insomnia/}i            => 'Insomnia'],
  [qr{\bhttpie/}i            => 'HTTPie'],
  [qr{guzzlehttp}i           => 'Guzzle'],
);

my $GENERIC_BOT = qr{
  \bbot\b | bot/ | bot\) | crawl | spider | scrap | \bslurp\b
  | feedfetch | \bfetch\b | harvest | archiver | nutch | heritrix
  | headless | phantom | httpclient | http-client | \brobot\b
  | \(\+https?:// | site\s?audit | \bprobe\b | \bscanner\b
}xi;

sub parse {
  my ($ua) = @_;
  $ua = '' unless defined $ua;
  $ua =~ s/^\s+//;
  $ua =~ s/\s+$//;

  return _result('other', 0, undef, undef, undef, 'other') if $ua eq '';

  if (_is_bot($ua)) {
    return _result('bot', 1, _clean($ua), undef, undef, 'bot');
  }

  my $os      = _os($ua);
  my $browser = _browser($ua);
  my $device  = _device($ua, $os);
  my $class   = ($device eq 'mobile' || $device eq 'tablet') ? 'mobile'
    : ($device eq 'desktop') ? 'browser'
    :                          'other';
  return _result($class, 0, undef, $browser, $os, $device);
}

sub _result {
  my ($class, $is_bot, $bot_ua, $browser, $os, $device) = @_;
  return {
    ua_class => $class,
    is_bot   => $is_bot,
    bot_ua   => $bot_ua,
    browser  => $browser,
    os       => $os,
    device   => $device,
  };
}

sub _is_bot {
  my ($ua) = @_;
  for my $b (@BOTS) {
    return 1 if $ua =~ $b->[0];
  }
  return 1 if $ua =~ $GENERIC_BOT;

  # A UA that is only a bare token with no browser engine is almost
  # never a real browser.
  return 1 if $ua !~ /mozilla/i && $ua !~ m{ } && $ua =~ m{/};
  return 0;
}

sub _os {
  my ($ua) = @_;
  return 'Android'  if $ua =~ /android/i;
  return 'iOS'      if $ua =~ /iphone|ipad|ipod/i;
  return 'Windows'  if $ua =~ /windows nt|windows phone|win64|win32/i;
  return 'ChromeOS' if $ua =~ /\bcros\b/i;
  return 'macOS'    if $ua =~ /mac os x|macintosh/i;
  return 'BSD'      if $ua =~ /freebsd|openbsd|netbsd|dragonfly/i;
  return 'Linux'    if $ua =~ /linux|x11|ubuntu|fedora/i;
  return 'other';
}

sub _browser {
  my ($ua) = @_;
  return 'Edge'             if $ua =~ m{\bedg(?:e|a|ios)?/}i;
  return 'Opera'            if $ua =~ m{\bopr/|\bopera[/ ]}i;
  return 'Vivaldi'          if $ua =~ /vivaldi/i;
  return 'Samsung Internet' if $ua =~ /samsungbrowser/i;
  return 'UC Browser'       if $ua =~ /ucbrowser/i;
  return 'Yandex Browser'   if $ua =~ /yabrowser/i;
  return 'Firefox'          if $ua =~ m{\bfirefox/|\bfxios/}i;
  return 'Pale Moon'        if $ua =~ /palemoon/i;
  return 'Chrome'           if $ua =~ m{\bchrom(?:e|ium)/|\bcrios/}i;
  return 'Safari'           if $ua =~ m{\bsafari/}i && $ua =~ m{\bversion/}i;
  return 'IE'               if $ua =~ m{msie |trident/}i;
  return 'other';
}

sub _device {
  my ($ua, $os) = @_;
  return 'tablet' if $ua =~ /ipad/i;
  return 'tablet' if $os eq 'Android' && $ua !~ /mobile/i;
  return 'mobile' if $ua =~ /mobile|iphone|ipod|windows phone/i;
  return 'mobile' if $os eq 'iOS';
  return 'desktop' if $os =~ /^(?:Windows|macOS|Linux|ChromeOS|BSD)$/;
  return 'other';
}

sub _clean {
  my ($ua) = @_;
  $ua =~ s/[^\x20-\x7e]+/ /g;
  $ua =~ s/\s+/ /g;
  $ua =~ s/^\s+//;
  $ua =~ s/\s+$//;
  return length($ua) > 300 ? substr($ua, 0, 300) : $ua;
}

1;
