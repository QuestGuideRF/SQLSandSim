import 'dotenv/config';
import express from 'express';
import http from 'http';
import { Pool } from 'pg';
import { WebSocketServer } from 'ws';
import path from 'path';
import { fileURLToPath } from 'url';

const {
  PORT = 3000,
  TICK_MS = 50,
  PUSH_MS = 50,
  INIT_W = 256,
  INIT_H = 144,
  KEEP_FRAMES = 900
} = process.env;

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const pool = new Pool({
  host: process.env.PGHOST ?? "127.0.0.1",
  port: process.env.PGPORT ? Number(process.env.PGPORT) : 5342,
  user: process.env.PGUSER ?? "postgres",
  password: process.env.PGPASSWORD ?? "postgres",
  database: process.env.PGDATABASE ?? "postgres",
  max: 10
});

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

const nowIso = () => {
  return new Date().toISOString();
}

const wsBroadcast = (data) => {
  const msg = JSON.stringify(data);
  for (const ws of wss.clients) {
    if (ws.readyState === ws.OPEN) ws.send(msg);
  }
}

const queryForFirstRow = async (sql, params = []) => {
  const r = await pool.query(sql, params);
  return r.rows[0] ?? null;
}

async function getState() {
  return await queryForFirstRow('SELECT * FROM sim_get_state()');
}

async function getStatus() {
  return await queryForFirstRow('SELECT * FROM sim_status()');
}

const broadcastState = async () => {
  const row = await getState();
  if (!row) return;

  wsBroadcast({
    type: 'state',
    at: nowIso(),
    w: row.w,
    h: row.h,
    chunks: row.chunks,
    tick: row.tick,
    running: row.running,
    solid: row.solid,
    sand: row.sand
  });
}

const broadcastError = async (where, err) => {
  const payload = {
    type: 'error',
    at: nowIso(),
    where,
    message: err?.message ?? String(err),
    detail: err?.detail ?? null,
    hint: err?.hint ?? null,
    code: err?.code ?? null
  };

  wsBroadcast(payload);
}

app.post('/api/init', async (req, res) => {
  try {
    const w = Number(req.body?.w ?? INIT_W);
    const h = Number(req.body?.h ?? INIT_H);
    const keep = Number(req.body?.keepFrames ?? KEEP_FRAMES);

    await pool.query('SELECT sim_init($1,$2,$3)', [w, h, keep]);
    await broadcastState();

    res.json({
      ok: true
    });
  } catch (e) {
    await broadcastError('/api/init', e);

    res.status(500).json({
      ok: false,
      error: e.message
    });
  }
});

app.post('/api/start', async (_req, res) => {
  try {
    await pool.query('SELECT sim_start()');
    await broadcastState();

    res.json({
      ok: true
    });
  } catch (e) {
    await broadcastError('/api/start', e);

    res.status(500).json({
      ok: false,
      error: e.message
    });
  }
});

app.post('/api/stop', async (_req, res) => {
  try {
    await pool.query('SELECT sim_stop()');
    await broadcastState();

    res.json({
      ok: true
    });
  } catch (e) {
    await broadcastError('/api/stop', e);

    res.status(500).json({
      ok: false,
      error: e.message
    });
  }
});

app.get('/api/status', async (_req, res) => {
  try {
    const status = await getStatus();

    res.json(
      status ?? null
    );
  } catch (e) {
    await broadcastError('/api/status', e);

    res.status(500).json({
      ok: false,
      error: e.message
    });
  }
});

app.get('/api/state', async (_req, res) => {
  try {
    const state = await getState();

    res.json(
      state ?? null
    );
  } catch (e) {
    await broadcastError('/api/state', e);

    res.status(500).json({
      ok: false,
      error: e.message
    });
  }
});

app.post('/api/sand', async (req, res) => {
  try {
    const x = Number(req.body?.x ?? 0);
    const y = Number(req.body?.y ?? 0);
    const w = Number(req.body?.w ?? 20);
    const h = Number(req.body?.h ?? 12);

    await pool.query('SELECT sim_add_sand_rect($1,$2,$3,$4)', [x, y, w, h]);
    await broadcastState();

    res.json({
      ok: true
    });
  } catch (e) {
    await broadcastError('/api/sand', e);

    res.status(500).json({
      ok: false, error: e.message
    });
  }
});

app.post('/api/solid', async (req, res) => {
  try {
    const x = Number(req.body?.x ?? 0);
    const y = Number(req.body?.y ?? 0);
    const w = Number(req.body?.w ?? 20);
    const h = Number(req.body?.h ?? 12);

    await pool.query('SELECT sim_add_solid_rect($1,$2,$3,$4)', [x, y, w, h]);
    await broadcastState();

    res.json({
      ok: true
    });
  } catch (e) {
    await broadcastError('/api/solid', e);

    res.status(500).json({
      ok: false,
      error: e.message
    });
  }
});

app.get('/api/history', async (_req, res) => {
  try {
    const r = await pool.query('SELECT * FROM sim_history_range()');

    res.json(
      r.rows[0] ?? {
        min_tick: null,
        max_tick: null
      }
    );
  } catch (e) {
    await broadcastError('/api/history', e);

    res.status(500).json({
      ok: false,
      error: e.message
    });
  }
});

app.post('/api/rewind', async (req, res) => {
  try {
    const tick = Number(req.body?.tick ?? 0);
    const r = await pool.query('SELECT sim_rewind($1) AS tick', [tick]);
    await broadcastState();

    res.json({
      ok: true,
      tick: r.rows[0].tick
    });
  } catch (e) {
    await broadcastError('/api/rewind', e);

    res.status(500).json({
      ok: false,
      error: e.message
    });
  }
});

const server = http.createServer(app);
const wss = new WebSocketServer({ server });

wss.on('connection', async (ws) => {
  ws.send(JSON.stringify({ type: 'hello', at: nowIso() }));
  try {
    await broadcastState();
  } catch (e) {
    await broadcastError('ws-initial-broadcast', e);
  }
});

let tickRunning = false;
let pushRunning = false;

const tickLoop = async () => {
  if (tickRunning) {
    return;
  }

  tickRunning = true;
  try {
    while (true) {
      const start = Date.now();

      try {
        await pool.query('SELECT sim_step()');
      } catch (e) {
        await broadcastError('sim_step', e);
      }

      const elapsed = Date.now() - start;
      const sleep = Math.max(0, Number(TICK_MS) - elapsed);
      await new Promise(r => setTimeout(r, sleep));
    }
  } finally {
    tickRunning = false;
  }
}

const pushLoop = async () => {
  if (pushRunning) {
    return;
  }

  pushRunning = true;
  try {
    while (true) {
      const start = Date.now();

      try {
        await broadcastState();
      } catch (e) {
        await broadcastError('broadcastState', e);
      }

      const elapsed = Date.now() - start;
      const sleep = Math.max(0, Number(PUSH_MS) - elapsed);
      await new Promise(r => setTimeout(r, sleep));
    }
  } finally {
    pushRunning = false;
  }
}

server.listen(Number(PORT), async () => {
  console.log(`Server listening on http://localhost:${PORT}`);

  tickLoop();
  pushLoop();
});