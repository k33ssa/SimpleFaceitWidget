CREATE TABLE IF NOT EXISTS players (
  player_id TEXT PRIMARY KEY,
  last_elo INTEGER,
  last_game_id TEXT,
  record_base_elo INTEGER,     -- ELO after the last recorded game (or first seen)
  pending_game_id TEXT,         -- newest game whose ELO change we are waiting for
  pending_match_id TEXT,
  pending_since INTEGER,
  pending_gap INTEGER,          -- how many new games appeared at once
  polled_at INTEGER,
  last_client_at INTEGER,
  created_at INTEGER
);
CREATE TABLE IF NOT EXISTS elo_records (
  player_id TEXT NOT NULL,
  game_id TEXT NOT NULL,        -- "<matchId>#<round>", same as the app
  match_id TEXT NOT NULL,
  elo INTEGER NOT NULL,         -- ELO right after this game
  recorded_at INTEGER NOT NULL,
  gap INTEGER NOT NULL DEFAULT 1, -- 1 = exactly this game since the previous record (exact delta)
  PRIMARY KEY (player_id, game_id)
);
CREATE TABLE IF NOT EXISTS log (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, message TEXT NOT NULL
);
