-- iczelia.net - personal CMS and static site engine.
-- Copyright (C) 2026 Kamila Szewczyk
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as
-- published by the Free Software Foundation, either version 3 of the
-- License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.

-- Initial seed data: default settings and empty fixed-page rows.

INSERT OR IGNORE INTO settings (key, value) VALUES
  ('site.title',        'iczelia'),
  ('site.tagline',      'personal site v2.0'),
  ('site.description',  'Personal site, blog, and journal of Kamila Szewczyk.'),
  ('site.keywords',     ''),
  ('site.og_image',     ''),
  ('site.author',       'Kamila Szewczyk'),
  ('site.email',        'k@iczelia.net'),
  ('site.base_url',     'https://iczelia.net'),
  ('site.copyright',    '(c) 2019 - 2026 iczelia (Kamila Szewczyk)'),
  ('github.username',   'iczelia'),
  ('github.url',        'https://github.com/iczelia'),
  ('mastodon.handle',   '@iczelia@glauca.space'),
  ('mastodon.url',      'https://glauca.space/@iczelia'),
  ('mastodon.feed_url', 'https://glauca.space/@iczelia.rss'),
  ('bluesky.handle',    'iczelia.net'),
  ('bluesky.url',       'https://bsky.app/profile/iczelia.net'),
  ('fetcher.timeout_s', '10'),
  ('fetcher.user_agent','iczelia.net-fetcher/1.0 (+https://iczelia.net)');

-- Fixed-page rows. `data` is a JSON blob; the actual content lives in
-- the data column of each row. Initial values are deliberately empty -
-- the admin fills them in via /admin/edit/<page>.

INSERT OR IGNORE INTO pages (slug, title, template, data, updated_at) VALUES
  ('home',      'iczelia :: personal site v2.0', 'home',      '{}', strftime('%s','now')),
  ('about',     'iczelia :: about',              'about',     '{}', strftime('%s','now')),
  ('cv',        'iczelia :: cv',                 'cv',        '{}', strftime('%s','now')),
  ('blog',      'iczelia :: blog',               'list',      '{"intro":""}', strftime('%s','now')),
  ('journal',   'iczelia :: journal',            'list',      '{"intro":""}', strftime('%s','now')),
  ('webring',   'iczelia :: webring',            'webring',   '{"intro":""}', strftime('%s','now')),
  ('guestbook', 'iczelia :: guestbook',          'guestbook', '{"intro":""}', strftime('%s','now'));
