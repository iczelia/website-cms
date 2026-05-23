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

CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS auth (
  username TEXT PRIMARY KEY,
  pwhash   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  sid         TEXT PRIMARY KEY,
  username    TEXT NOT NULL REFERENCES auth(username),
  expires_at  INTEGER NOT NULL,
  ip          TEXT,
  created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_expires ON sessions(expires_at);

CREATE TABLE IF NOT EXISTS pages (
  slug          TEXT PRIMARY KEY,
  title         TEXT NOT NULL,
  template      TEXT NOT NULL,
  data          TEXT NOT NULL,
  rendered_html TEXT,
  rendered_at   INTEGER,
  updated_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS posts (
  id              INTEGER PRIMARY KEY,
  kind            TEXT    NOT NULL CHECK (kind IN ('blog','journal')),
  slug            TEXT    NOT NULL,
  title           TEXT    NOT NULL,
  date            TEXT    NOT NULL,
  tags            TEXT    NOT NULL DEFAULT '',
  draft           INTEGER NOT NULL DEFAULT 0,
  body            TEXT    NOT NULL,
  word_count      INTEGER NOT NULL DEFAULT 0,
  publish_at      INTEGER,
  -- Editorial classification: zero, one, or two Greek letters that
  -- describe the post's flavour. Stored as the literal codepoints
  -- separated by a single space; rendered as a leading glyph.
  --   φ philosophy   π science   λ code/engineering
  --   δ release      ω opinion/retrospective   μ meta/personal
  kappa           TEXT    NOT NULL DEFAULT '',
  -- Series grouping: post belongs to series.id with the given 1-based
  -- position. Both are NULL for one-off posts. No FK constraint so the
  -- column can be backfilled by hand; the app enforces referential
  -- integrity.
  series_id       INTEGER,
  series_position INTEGER,
  rendered_html   TEXT,
  rendered_at     INTEGER,
  created_at      INTEGER NOT NULL DEFAULT 0,
  updated_at      INTEGER NOT NULL,
  UNIQUE (kind, slug)
);
CREATE INDEX IF NOT EXISTS posts_kind_date ON posts(kind, date DESC, created_at DESC);
CREATE INDEX IF NOT EXISTS posts_series ON posts(series_id, series_position);

-- Post series (multi-part collections). The post's series_id points
-- here, and series_position orders them within the series.
CREATE TABLE IF NOT EXISTS series (
  id          INTEGER PRIMARY KEY,
  slug        TEXT    NOT NULL UNIQUE,
  title       TEXT    NOT NULL,
  description TEXT    NOT NULL DEFAULT '',
  created_at  INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  updated_at  INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

-- Per-post slug aliases. When a post is renamed, the old slug becomes a
-- 301 redirect to the canonical URL.
CREATE TABLE IF NOT EXISTS post_aliases (
  kind        TEXT    NOT NULL CHECK (kind IN ('blog','journal')),
  from_slug   TEXT    NOT NULL,
  post_id     INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (kind, from_slug)
);
CREATE INDEX IF NOT EXISTS post_aliases_post ON post_aliases(post_id);

-- Edit history: a snapshot is taken on every update_post(). Capped at 50
-- per post by the writer.
CREATE TABLE IF NOT EXISTS post_revisions (
  id            INTEGER PRIMARY KEY,
  post_id       INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  revision_num  INTEGER NOT NULL,
  title         TEXT    NOT NULL,
  body          TEXT    NOT NULL,
  tags          TEXT    NOT NULL DEFAULT '',
  date          TEXT    NOT NULL,
  draft         INTEGER NOT NULL DEFAULT 0,
  publish_at    INTEGER,
  author        TEXT,
  created_at    INTEGER NOT NULL,
  UNIQUE (post_id, revision_num)
);
CREATE INDEX IF NOT EXISTS post_revisions_post ON post_revisions(post_id, revision_num DESC);

-- On-site search. SQLite FTS5 contentless table fed by triggers on posts.
CREATE VIRTUAL TABLE IF NOT EXISTS posts_fts USING fts5(
  slug, kind UNINDEXED, title, body, tags,
  content='posts', content_rowid='id',
  tokenize='unicode61 remove_diacritics 2'
);
CREATE TRIGGER IF NOT EXISTS posts_fts_ai AFTER INSERT ON posts BEGIN
  INSERT INTO posts_fts(rowid, slug, kind, title, body, tags)
    VALUES (new.id, new.slug, new.kind, new.title, new.body, new.tags);
END;
CREATE TRIGGER IF NOT EXISTS posts_fts_ad AFTER DELETE ON posts BEGIN
  INSERT INTO posts_fts(posts_fts, rowid, slug, kind, title, body, tags)
    VALUES ('delete', old.id, old.slug, old.kind, old.title, old.body, old.tags);
END;
CREATE TRIGGER IF NOT EXISTS posts_fts_au
AFTER UPDATE OF slug, kind, title, body, tags ON posts BEGIN
  INSERT INTO posts_fts(posts_fts, rowid, slug, kind, title, body, tags)
    VALUES ('delete', old.id, old.slug, old.kind, old.title, old.body, old.tags);
  INSERT INTO posts_fts(rowid, slug, kind, title, body, tags)
    VALUES (new.id, new.slug, new.kind, new.title, new.body, new.tags);
END;

-- Admin-defined dynamic top-level pages (e.g. /zine/, /about/now/).
CREATE TABLE IF NOT EXISTS dynamic_pages (
  id            INTEGER PRIMARY KEY,
  route         TEXT    NOT NULL UNIQUE,
  title         TEXT    NOT NULL,
  template      TEXT    NOT NULL DEFAULT 'generic',
  data          TEXT    NOT NULL,
  rendered_html TEXT,
  rendered_at   INTEGER,
  updated_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS dynamic_pages_route ON dynamic_pages(route);

-- Static subpages: admin-uploaded HTML/CSS/JS bundles mounted under
-- /<slug>/. subpage_files holds the bundle, one row per file; index.html
-- is served for a directory request.
CREATE TABLE IF NOT EXISTS subpages (
  id         INTEGER PRIMARY KEY,
  slug       TEXT    NOT NULL UNIQUE,
  title      TEXT    NOT NULL DEFAULT '',
  listing    INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS subpage_files (
  id           INTEGER PRIMARY KEY,
  subpage_id   INTEGER NOT NULL REFERENCES subpages(id) ON DELETE CASCADE,
  path         TEXT    NOT NULL,
  content      BLOB    NOT NULL,
  content_type TEXT    NOT NULL,
  size         INTEGER NOT NULL,
  is_binary    INTEGER NOT NULL DEFAULT 0,
  updated_at   INTEGER NOT NULL,
  UNIQUE (subpage_id, path)
);
CREATE INDEX IF NOT EXISTS subpage_files_pid ON subpage_files(subpage_id);

-- Admin-defined highlighter languages. Word-list-only definitions; the
-- runtime quotemetas every token before building regex rules.
CREATE TABLE IF NOT EXISTS highlight_langs (
  id             INTEGER PRIMARY KEY,
  name           TEXT    NOT NULL UNIQUE,
  aliases        TEXT    NOT NULL DEFAULT '',
  keywords       TEXT    NOT NULL DEFAULT '',
  types          TEXT    NOT NULL DEFAULT '',
  builtins       TEXT    NOT NULL DEFAULT '',
  line_comment   TEXT    NOT NULL DEFAULT '',
  block_comment  TEXT    NOT NULL DEFAULT '',
  string_quotes  TEXT    NOT NULL DEFAULT '"',
  updated_at     INTEGER NOT NULL,
  version        INTEGER NOT NULL DEFAULT 1
);

-- Server-side analytics. analytics_events is the rolling raw buffer
-- (capped to ~250k rows by the aggregator). analytics_daily and
-- analytics_referrers are the long-term roll-up.
-- browser/os hold derived families for human visitors only; bot_ua
-- holds the raw (cleaned) UA string for bots. A raw human UA is never
-- stored.
CREATE TABLE IF NOT EXISTS analytics_events (
  id            INTEGER PRIMARY KEY,
  ts            INTEGER NOT NULL,
  path          TEXT    NOT NULL,
  status        INTEGER NOT NULL,
  method        TEXT    NOT NULL,
  visitor_hash  TEXT    NOT NULL,
  referer_host  TEXT,
  ua_class      TEXT    NOT NULL,
  browser       TEXT,
  os            TEXT,
  device        TEXT,
  bot_ua        TEXT
);
CREATE INDEX IF NOT EXISTS analytics_events_ts ON analytics_events(ts DESC);
CREATE TABLE IF NOT EXISTS analytics_daily (
  date     TEXT    NOT NULL,
  path     TEXT    NOT NULL,
  views    INTEGER NOT NULL DEFAULT 0,
  uniques  INTEGER NOT NULL DEFAULT 0,
  bots     INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (date, path)
);
CREATE TABLE IF NOT EXISTS analytics_referrers (
  date         TEXT    NOT NULL,
  referer_host TEXT    NOT NULL,
  count        INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (date, referer_host)
);

-- Daily roll-up of UA breakdowns. kind is 'browser', 'os', 'device'
-- or 'bot'; label is the family name (or raw bot UA for kind='bot').
CREATE TABLE IF NOT EXISTS analytics_ua (
  date  TEXT    NOT NULL,
  kind  TEXT    NOT NULL,
  label TEXT    NOT NULL,
  count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (date, kind, label)
);

CREATE TABLE IF NOT EXISTS updates (
  id       INTEGER PRIMARY KEY,
  date     TEXT    NOT NULL,
  body     TEXT    NOT NULL,
  position INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS activity (
  id         INTEGER PRIMARY KEY,
  source     TEXT NOT NULL,
  text       TEXT NOT NULL,
  url        TEXT,
  posted_at  INTEGER,
  position   INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS activity_source_pos ON activity(source, position);

CREATE TABLE IF NOT EXISTS webring_members (
  id        INTEGER PRIMARY KEY,
  position  INTEGER NOT NULL,
  section   TEXT    NOT NULL DEFAULT 'others',  -- 'own' | 'others' | 'more'
  name      TEXT    NOT NULL,
  url       TEXT,
  image_url TEXT
);

CREATE TABLE IF NOT EXISTS guestbook_entries (
  id               INTEGER PRIMARY KEY,
  posted_at        INTEGER NOT NULL,
  approved_at      INTEGER,
  rejected_at      INTEGER,
  nickname         TEXT NOT NULL,
  body_md          TEXT NOT NULL,
  body_html        TEXT,
  ip               TEXT NOT NULL,
  user_agent       TEXT,
  admin_reply_md   TEXT,
  admin_reply_html TEXT,
  admin_replied_at INTEGER
);
CREATE INDEX IF NOT EXISTS guestbook_pending  ON guestbook_entries(approved_at, rejected_at);
CREATE INDEX IF NOT EXISTS guestbook_approved ON guestbook_entries(approved_at);

CREATE TABLE IF NOT EXISTS guestbook_throttle (
  ip            TEXT PRIMARY KEY,
  attempts      INTEGER NOT NULL,
  window_start  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS media (
  id             INTEGER PRIMARY KEY,
  filename       TEXT NOT NULL,
  orig_name      TEXT NOT NULL,
  content_type   TEXT NOT NULL,
  size           INTEGER NOT NULL,
  sha256         TEXT NOT NULL UNIQUE,
  uploaded_at    INTEGER NOT NULL,
  thumb_filename TEXT
);

CREATE TABLE IF NOT EXISTS tex_cache (
  hash       TEXT PRIMARY KEY,
  display    INTEGER NOT NULL,
  html       TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS login_throttle (
  ip            TEXT PRIMARY KEY,
  attempts      INTEGER NOT NULL,
  window_start  INTEGER NOT NULL
);

-- Pre-rendered, pre-compressed responses for public GET requests.  Body
-- is stored uncompressed plus zopfli-gzipped and brotli-encoded variants
-- so we can content-negotiate without paying compression cost on hits.
CREATE TABLE IF NOT EXISTS response_cache (
  path         TEXT PRIMARY KEY,
  status       INTEGER NOT NULL,
  content_type TEXT NOT NULL,
  body         BLOB NOT NULL,
  body_gz      BLOB,
  body_br      BLOB,
  etag         TEXT NOT NULL,
  created_at   INTEGER NOT NULL
);
