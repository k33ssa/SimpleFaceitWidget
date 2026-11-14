// SimpleFaceit backend (Cloudflare Worker).
//  • /v1/data/<path>  — proxy to the official FACEIT Data API v4 (whitelisted paths). The API key lives only here.
//  • /v1/elo/<id>     — exact per-match ELO recorded by polling; also starts tracking the player.
//  • cron, every minute — for each tracked player: current ELO + newest game; when a new game appears and the
//    ELO changes, store "ELO right after that game". Official API only — no scraping, nothing to bypass.

export interface Env {
  DB: D1Database;
  FACEIT_API_KEY: string;
  APP_TOKEN: string;
}

const FACEIT = "https://open.faceit.com/data/v4/";
const PENDING_TIMEOUT_MS = 20 * 60 * 1000;   // no ELO change 20 min after a game → it was unrated (Δ 0)
const ACTIVE_CLIENT_MS = 14 * 24 * 3600 * 1000; // stop polling players nobody asked about for 2 weeks

const ALLOWED = [
  /^players$/,
  /^players\/[0-9a-f-]{36}$/,
  /^players\/[0-9a-f-]{36}\/games\/cs2\/stats$/,
  /^players\/[0-9a-f-]{36}\/stats\/cs2$/,
  /^search\/players$/,
  /^matches\/[0-9a-zA-Z-]+$/,
  /^matches\/[0-9a-zA-Z-]+\/stats$/,
  /^rankings\/games\/cs2\/regions\/[A-Za-z]+\/players\/[0-9a-f-]{36}$/,
];

const json = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...extra } });

function authorized(req: Request, env: Env): boolean {
  const h = req.headers.get("authorization") ?? "";
  return env.APP_TOKEN !== undefined && h === `Bearer ${env.APP_TOKEN}`;
}

async function faceit(env: Env, path: string, search = ""): Promise<Response> {
  return fetch(FACEIT + path + search, {
    headers: { authorization: `Bearer ${env.FACEIT_API_KEY}`, accept: "application/json" },
  });
}

async function log(env: Env, message: string) {
  await env.DB.prepare("INSERT INTO log(ts, message) VALUES(?, ?)").bind(Date.now(), message).run();
  await env.DB.prepare("DELETE FROM log WHERE id <= (SELECT MAX(id) FROM log) - 2000").run();
}

// ---------------- HTTP ----------------

async function handleData(req: Request, env: Env, ctx: ExecutionContext, path: string, url: URL): Promise<Response> {
  if (!ALLOWED.some((r) => r.test(path))) return json({ error: "path_not_allowed" }, 404);
  const cache = caches.default;
  const cacheKey = new Request(`https://cache.simplefaceit/${path}${url.search}`);
  const hit = await cache.match(cacheKey);
  if (hit) return hit;

  const upstream = await faceit(env, path, url.search);
  const body = await upstream.text();
  const headers: Record<string, string> = { "content-type": "application/json" };
  for (const h of ["ratelimit-limit", "ratelimit-remaining", "ratelimit-reset", "retry-after"]) {
    const v = upstream.headers.get(h);
    if (v) headers[h] = v;
  }
  const res = new Response(body, { status: upstream.status, headers });
  if (upstream.ok) {
    // Finished matches never change; profiles/stats are cached briefly so many widgets don't multiply requests.
    const ttl = path.startsWith("matches/") ? 86400 : 45;
    const cached = new Response(body, { status: 200, headers: { ...headers, "cache-control": `max-age=${ttl}` } });
    ctx.waitUntil(cache.put(cacheKey, cached));
  }
  // Seeing a profile request is the moment to start tracking that player.
  const m = path.match(/^players\/([0-9a-f-]{36})$/);
  if (m && upstream.ok) ctx.waitUntil(track(env, m[1]));
  return res;
}

async function track(env: Env, playerId: string) {
  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO players(player_id, created_at, last_client_at) VALUES(?, ?, ?)
     ON CONFLICT(player_id) DO UPDATE SET last_client_at = excluded.last_client_at`,
  ).bind(playerId, now, now).run();
}

async function handleElo(env: Env, ctx: ExecutionContext, playerId: string): Promise<Response> {
  if (!/^[0-9a-f-]{36}$/.test(playerId)) return json({ error: "bad_player_id" }, 400);
  await track(env, playerId);
  const p = await env.DB.prepare("SELECT * FROM players WHERE player_id = ?").bind(playerId).first<PlayerRow>();
  if (p && !p.polled_at) ctx.waitUntil(poll(env, p)); // first request: start right away, not at the next cron tick
  const { results } = await env.DB.prepare(
    "SELECT game_id, match_id, elo, recorded_at, gap FROM elo_records WHERE player_id = ? ORDER BY recorded_at DESC LIMIT 200",
  ).bind(playerId).all();
  return json({
    playerId,
    currentElo: p?.last_elo ?? null,
    polledAt: p?.polled_at ?? null,
    trackingSince: p?.created_at ?? null,
    records: results,
  });
}

// ---------------- polling ----------------

interface PlayerRow {
  player_id: string;
  last_elo: number | null;
  last_game_id: string | null;
  record_base_elo: number | null;
  pending_game_id: string | null;
  pending_match_id: string | null;
  pending_since: number | null;
  pending_gap: number | null;
  polled_at: number | null;
  last_client_at: number | null;
  created_at: number | null;
}

type Stats = Record<string, string | number>;

async function poll(env: Env, p: PlayerRow) {
  const [profRes, gamesRes] = await Promise.all([
    faceit(env, `players/${p.player_id}`),
    faceit(env, `players/${p.player_id}/games/cs2/stats`, "?offset=0&limit=10"),
  ]);
  if (!profRes.ok || !gamesRes.ok) {
    await log(env, `poll ${p.player_id}: HTTP ${profRes.status}/${gamesRes.status}`);
    return;
  }
  const prof = (await profRes.json()) as { games?: { cs2?: { faceit_elo?: number } } };
  const elo = prof.games?.cs2?.faceit_elo;
  if (typeof elo !== "number") return;
  const items = ((await gamesRes.json()) as { items?: { stats: Stats }[] }).items ?? [];
  const games = items
    .map((i) => ({
      id: `${i.stats["Match Id"]}#${i.stats["Match Round"] ?? "1"}`,
      matchId: String(i.stats["Match Id"]),
      finished: Number(i.stats["Match Finished At"] ?? 0),
    }))
    .filter((g) => g.matchId && g.matchId !== "undefined")
    .sort((a, b) => b.finished - a.finished);
  const newest = games[0];
  const now = Date.now();

  let s = { ...p };
  if (s.last_game_id === null) {
    // First look: we can't know ELO after games played before tracking started.
    s.last_game_id = newest?.id ?? null;
    s.record_base_elo = elo;
  } else if (newest && newest.id !== s.last_game_id) {
    const idx = games.findIndex((g) => g.id === s.last_game_id);
    const gap = idx === -1 ? games.length : idx; // new games since the last poll
    s.pending_game_id = newest.id;
    s.pending_match_id = newest.matchId;
    s.pending_since = now;
    s.pending_gap = (s.pending_game_id && p.pending_game_id ? (p.pending_gap ?? 1) : 0) + gap;
    s.last_game_id = newest.id;
  }

  if (s.pending_game_id) {
    const changed = s.record_base_elo !== null && elo !== s.record_base_elo;
    const timedOut = now - (s.pending_since ?? now) > PENDING_TIMEOUT_MS;
    if (changed || timedOut) {
      await env.DB.prepare(
        `INSERT INTO elo_records(player_id, game_id, match_id, elo, recorded_at, gap) VALUES(?, ?, ?, ?, ?, ?)
         ON CONFLICT(player_id, game_id) DO NOTHING`,
      ).bind(s.player_id, s.pending_game_id, s.pending_match_id, elo, now, Math.max(1, s.pending_gap ?? 1)).run();
      await log(env, `record ${s.player_id} ${s.pending_game_id} elo ${elo} (${elo - (s.record_base_elo ?? elo)}), gap ${s.pending_gap}`);
      s.record_base_elo = elo;
      s.pending_game_id = null;
      s.pending_match_id = null;
      s.pending_since = null;
      s.pending_gap = null;
    }
  } else if (s.record_base_elo !== null && elo !== s.record_base_elo && s.last_elo === elo) {
    // ELO changed with no new game and stayed changed for a poll: an off-match adjustment; don't pin it on a game.
    s.record_base_elo = elo;
  }

  await env.DB.prepare(
    `UPDATE players SET last_elo=?, last_game_id=?, record_base_elo=?, pending_game_id=?, pending_match_id=?,
     pending_since=?, pending_gap=?, polled_at=? WHERE player_id=?`,
  ).bind(elo, s.last_game_id, s.record_base_elo, s.pending_game_id, s.pending_match_id, s.pending_since,
    s.pending_gap, now, s.player_id).run();
}

async function pollAll(env: Env) {
  const since = Date.now() - ACTIVE_CLIENT_MS;
  const { results } = await env.DB.prepare("SELECT * FROM players WHERE last_client_at >= ? LIMIT 200")
    .bind(since).all<PlayerRow>();
  for (const p of results) {
    try { await poll(env, p); } catch (e) { await log(env, `poll ${p.player_id} failed: ${String(e)}`); }
  }
}

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/health") return json({ ok: true });
    if (!authorized(req, env)) return json({ error: "unauthorized" }, 401);
    if (req.method !== "GET") return json({ error: "method" }, 405);
    if (url.pathname.startsWith("/v1/data/")) {
      return handleData(req, env, ctx, url.pathname.slice("/v1/data/".length), url);
    }
    const elo = url.pathname.match(/^\/v1\/elo\/([^/]+)$/);
    if (elo) return handleElo(env, ctx, elo[1]);
    return json({ error: "not_found" }, 404);
  },

  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(pollAll(env));
  },
} satisfies ExportedHandler<Env>;
