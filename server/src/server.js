'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 8787;
const DATA_FILE = path.join(__dirname, '..', 'data', 'data.json');
const ROOM_ID_RE = /^[a-f0-9]{16,64}$/;
const MAX_BODY_NOTES = 5000;
const ROOM_TTL_MS = 1000 * 60 * 60 * 24 * 90; // rooms idle for 90 days are purged

// In-memory store: roomId -> { notes: { [noteId]: {id, ciphertext, iv, updatedAt, deleted} }, lastSeenAt }
// The server only ever handles opaque ciphertext + a plaintext timestamp used for
// last-write-wins conflict resolution. It never sees a note's actual content.
let rooms = Object.create(null);
let saveTimer = null;

function loadRooms() {
  try {
    const raw = fs.readFileSync(DATA_FILE, 'utf8');
    rooms = JSON.parse(raw);
  } catch (err) {
    rooms = Object.create(null);
  }
}

function scheduleSave() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    fs.mkdirSync(path.dirname(DATA_FILE), { recursive: true });
    fs.writeFileSync(DATA_FILE, JSON.stringify(rooms));
  }, 500);
}

function getRoom(roomId) {
  let room = rooms[roomId];
  if (!room) {
    room = { notes: Object.create(null), lastSeenAt: Date.now() };
    rooms[roomId] = room;
  }
  room.lastSeenAt = Date.now();
  return room;
}

function isValidNote(n) {
  return (
    n &&
    typeof n.id === 'string' &&
    n.id.length > 0 &&
    n.id.length <= 128 &&
    typeof n.ciphertext === 'string' &&
    typeof n.iv === 'string' &&
    typeof n.updatedAt === 'number' &&
    Number.isFinite(n.updatedAt) &&
    typeof n.deleted === 'boolean'
  );
}

// Merges incoming notes into the room using last-write-wins on updatedAt.
// Returns the canonical (post-merge) version for every id that was submitted.
function mergeNotes(room, incoming) {
  const canonical = [];
  for (const note of incoming) {
    const existing = room.notes[note.id];
    if (!existing || note.updatedAt > existing.updatedAt) {
      room.notes[note.id] = note;
      canonical.push(note);
    } else {
      canonical.push(existing);
    }
  }
  scheduleSave();
  return canonical;
}

function purgeStaleRooms() {
  const now = Date.now();
  for (const roomId of Object.keys(rooms)) {
    if (now - rooms[roomId].lastSeenAt > ROOM_TTL_MS) {
      delete rooms[roomId];
    }
  }
  scheduleSave();
}

function readJsonBody(req, callback) {
  let body = '';
  let tooLarge = false;
  req.on('data', (chunk) => {
    body += chunk;
    if (body.length > 5 * 1024 * 1024) {
      tooLarge = true;
      req.destroy();
    }
  });
  req.on('end', () => {
    if (tooLarge) return;
    try {
      callback(null, JSON.parse(body || '{}'));
    } catch (err) {
      callback(err);
    }
  });
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (req.method === 'GET' && url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true }));
    return;
  }

  const syncMatch = url.pathname.match(/^\/rooms\/([^/]+)\/sync$/);
  if (req.method === 'POST' && syncMatch) {
    const roomId = syncMatch[1];
    if (!ROOM_ID_RE.test(roomId)) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'invalid room id' }));
      return;
    }
    readJsonBody(req, (err, body) => {
      if (err || !Array.isArray(body.notes) || body.notes.length > MAX_BODY_NOTES) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'invalid body' }));
        return;
      }
      if (!body.notes.every(isValidNote)) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'invalid note shape' }));
        return;
      }
      const room = getRoom(roomId);
      mergeNotes(room, body.notes);
      broadcastToRoom(roomId, { type: 'push', notes: body.notes.map((n) => room.notes[n.id]) }, null);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ notes: Object.values(room.notes) }));
    });
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found' }));
});

const wss = new WebSocketServer({ server, path: '/ws' });

// roomId -> Set<WebSocket>
const roomSockets = new Map();

function broadcastToRoom(roomId, message, exceptSocket) {
  const sockets = roomSockets.get(roomId);
  if (!sockets) return;
  const payload = JSON.stringify(message);
  for (const ws of sockets) {
    if (ws !== exceptSocket && ws.readyState === ws.OPEN) {
      ws.send(payload);
    }
  }
}

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const roomId = url.searchParams.get('room') || '';

  if (!ROOM_ID_RE.test(roomId)) {
    ws.close(4000, 'invalid room id');
    return;
  }

  let sockets = roomSockets.get(roomId);
  if (!sockets) {
    sockets = new Set();
    roomSockets.set(roomId, sockets);
  }
  sockets.add(ws);

  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch (err) {
      return;
    }
    if (!msg || !Array.isArray(msg.notes) || msg.notes.length > MAX_BODY_NOTES) return;
    if (!msg.notes.every(isValidNote)) return;

    const room = getRoom(roomId);

    if (msg.type === 'push') {
      const canonical = mergeNotes(room, msg.notes);
      ws.send(JSON.stringify({ type: 'push_ack', notes: canonical }));
      broadcastToRoom(roomId, { type: 'push', notes: canonical }, ws);
    } else if (msg.type === 'sync') {
      const canonical = mergeNotes(room, msg.notes);
      ws.send(JSON.stringify({ type: 'sync_result', notes: Object.values(room.notes) }));
      broadcastToRoom(roomId, { type: 'push', notes: canonical }, ws);
    }
  });

  ws.on('close', () => {
    sockets.delete(ws);
    if (sockets.size === 0) roomSockets.delete(roomId);
  });
});

loadRooms();
setInterval(purgeStaleRooms, 1000 * 60 * 60);

server.listen(PORT, () => {
  console.log(`notes-sync-relay listening on :${PORT}`);
});
