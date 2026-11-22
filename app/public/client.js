const CANVAS_BG = [20, 23, 26];
const CANVAS_SOLID = [69, 42, 20];
const CANVAS_SAND = [255, 215, 112];

const simCanvas = document.getElementById('sim_canvas');
const ctx = simCanvas.getContext('2d', { alpha: false });

const initBtn = document.getElementById('initBtn');
const startBtn = document.getElementById('startBtn');
const stopBtn = document.getElementById('stopBtn');
const tickVal = document.getElementById('tick');
const fpsVal = document.getElementById('fps');

const timeline = document.getElementById('timeline');
const timelineTickVal = document.getElementById('timelineTickVal');
const timelineGoToBtn = document.getElementById('timelineGoToBtn');

const brush = document.getElementById('brush');

const statusDiv = document.getElementById('status_logger');

let state = null;
let lastFrameTime = performance.now();
let fps = 0;
let lastTickSeen = null;
let lastWsMessageAt = Date.now();

const setStatus = (status) => {
  statusDiv.textContent = status;
}

const setCanvasSize = (w, h) => {
  const maxW = 1200;
  const maxH = 700;
  const scale = Math.max(2, Math.min(Math.floor(maxW / w), Math.floor(maxH / h)));

  simCanvas.width = w * scale;
  simCanvas.height = h * scale;
  ctx.imageSmoothingEnabled = false;

  return scale;
}

const chunkBitIsSet = (chunkStr, bit) => {
  const v = BigInt(chunkStr);

  return ((v >> BigInt(bit)) & 1n) === 1n;
}

const draw = () => {
  if (!state) {
    return;
  }

  const { w, h, solid, sand } = state;
  setCanvasSize(w, h);

  const img = ctx.createImageData(w, h);
  const data = img.data;

  for (let sy = 0; sy < h; sy++) {
    const rowSolid = solid[sy];
    const rowSand = sand[sy];
    const cy = (h - 1 - sy);

    for (let x = 0; x < w; x++) {
      const c = (x / 64) | 0;
      const b = x & 63;

      const isS = chunkBitIsSet(rowSolid[c], b);
      const isW = chunkBitIsSet(rowSand[c], b);

      const idx = (cy * w + x) * 4;

      let col = CANVAS_BG;
      if (isS) {
        col = CANVAS_SOLID;
      }
      else if (isW) {
        col = CANVAS_SAND;
      }

      data[idx + 0] = col[0];
      data[idx + 1] = col[1];
      data[idx + 2] = col[2];
      data[idx + 3] = 255;
    }
  }

  const tmp = document.createElement('canvas');
  tmp.width = w;
  tmp.height = h;
  tmp.getContext('2d', { alpha: false }).putImageData(img, 0, 0);

  ctx.clearRect(0, 0, simCanvas.width, simCanvas.height);
  ctx.drawImage(tmp, 0, 0, simCanvas.width, simCanvas.height);
}

const updateFps = () => {
  const now = performance.now();
  const dt = now - lastFrameTime;
  lastFrameTime = now;

  const inst = 1000 / Math.max(1, dt);
  fps = fps * 0.9 + inst * 0.1;
  fpsVal.textContent = fps.toFixed(1);
}

const api = async (path, body) => {
  const res = await fetch(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body ?? {})
  });

  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(data.error || `HTTP ${res.status}`);
  }

  return data;
}

const refreshHistoryRange = async () => {
  const res = await fetch('/api/history');
  const data = await res.json();

  if(data.error) {
    throw new Error(data.error || `HTTP ${res.status}`);
  }

  const min = data.min_tick ?? 0;
  const max = data.max_tick ?? 0;

  timeline.min = String(min);
  timeline.max = String(max);
  timeline.value = String(max);
  timelineTickVal.textContent = String(max);

  const enabled = max > min;
  timeline.disabled = !enabled;
  timelineGoToBtn.disabled = !enabled;
}

initBtn.onclick = async () => {
  await api('/api/init', { w: 256, h: 144, keepFrames: 900 });
  await refreshHistoryRange();
};

startBtn.onclick = async () => {
  await api('/api/start');
};

stopBtn.onclick = async () => {
  await api('/api/stop');
  await refreshHistoryRange();
};

timeline.oninput = () => {
  timelineTickVal.textContent = timeline.value;
};

timelineGoToBtn.onclick = async () => {
  const t = Number(timeline.value);
  await api('/api/rewind', { tick: t });
};

const getCellFromMouse = (ev) => {
  if (!state) {
    return null;
  }

  const rect = simCanvas.getBoundingClientRect();
  const mouseX = ev.clientX - rect.left;
  const mouseY = ev.clientY - rect.top;

  const cx = Math.floor((mouseX / rect.width) * state.w);
  let cy = Math.floor((mouseY / rect.height) * state.h);
  cy = (state.h - 1 - cy);

  return { x: cx, y: cy };
}

simCanvas.addEventListener('contextmenu', (e) => e.preventDefault());

simCanvas.addEventListener('mousedown', async (e) => {
  if (!state) {
    return;
  }

  const cell = getCellFromMouse(e);
  if (!cell) {
    return;
  }

  const brushVal = Math.max(1, Math.min(80, Number(brush.value || 14)));
  const x0 = cell.x - Math.floor(brushVal / 2);
  const y0 = cell.y - Math.floor(brushVal / 2);

  const isRight = (e.button === 2);
  const paint = isRight ? 'solid' : 'sand';

  if (paint === 'sand') {
    await api('/api/sand', { x: x0, y: y0, w: brushVal, h: brushVal });
  } else {
    await api('/api/solid', { x: x0, y: y0, w: brushVal, h: brushVal });
  }
});

const wsProto = location.protocol === 'https:' ? 'wss:' : 'ws:';
const ws = new WebSocket(`${wsProto}//${location.host}`);

ws.onopen = () => setStatus('ws: connected');
ws.onclose = () => setStatus('ws: disconnected (polling fallback active)');
ws.onerror = () => setStatus('ws: error (polling fallback active)');

ws.onmessage = (ev) => {
  lastWsMessageAt = Date.now();
  const msg = JSON.parse(ev.data);

  if (msg.type === 'error') {
    setStatus(
      `SERVER ERROR @ ${msg.at}\nwhere: ${msg.where}\ncode: ${msg.code ?? '-'}\n${msg.message}\n${msg.detail ?? ''}`
    );
    return;
  }

  if (msg.type === 'state') {
    state = msg;
    tickVal.textContent = String(msg.tick);

    if (lastTickSeen !== null && msg.tick === lastTickSeen && msg.running) {
      setStatus(`ws: connected\nrunning but tick not advancing\n(last tick=${msg.tick})`);
    } else {
      setStatus(`ws: connected\nrunning=${msg.running}\ntick=${msg.tick}`);
    }
    lastTickSeen = msg.tick;

    draw();
    updateFps();

    if (!msg.running && (msg.tick % 10) === 0) refreshHistoryRange().catch(() => { });
  }
};

setInterval(async () => {
  const stale = (Date.now() - lastWsMessageAt) > 1000;
  if (!stale){
    return;
  }

  try {
    const res = await fetch('/api/state');
    const data = await res.json();

    if (data && data.w) {
      state = { type: 'state', ...data };
      tickVal.textContent = String(state.tick);
      setStatus(`poll: ok\nrunning=${state.running}\ntick=${state.tick}`);
      draw();
    }
  } catch (e) {
    setStatus(`poll: failed\n${e.message}`);
  }
}, 500);

refreshHistoryRange().catch(() => { });