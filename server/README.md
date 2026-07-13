# Notes Sync Relay

A minimal relay server that lets the Notes Sync app synchronize notes between
paired devices without any account or email.

## What it does (and doesn't) see

The server only ever stores, per "room":

- an opaque encrypted blob (`ciphertext` + `iv`) per note
- a plaintext `updatedAt` timestamp, used only to decide which version wins
  when two devices edited the same note (last-write-wins)

The encryption key is derived on-device from the pairing code and is never
sent to the server, so the server operator cannot read note contents. The
`roomId` used for routing is itself derived from the pairing code via
HMAC-SHA256, so the server never sees the pairing code either.

## Run it

```bash
cd server
npm install
npm start        # listens on :8787 by default, set PORT to change it
```

Data is persisted to `server/data/data.json` so restarts don't lose notes.

Rooms that see no activity for 90 days are purged automatically.

## Making it reachable from your devices

Both the Windows PC and the Android phone need to reach this server over the
network:

- **Same Wi-Fi/LAN**: run the server on any always-on machine on your network
  (a PC, a Raspberry Pi, a NAS) and use its LAN IP, e.g. `http://192.168.1.10:8787`.
- **Anywhere**: deploy it to any small VPS or a free-tier host that supports
  long-lived WebSocket connections (e.g. Fly.io, Render, a cheap VPS with
  `pm2`/`systemd`), then use its public URL, e.g. `https://notes.example.com`.
  Put it behind HTTPS/WSS if it's exposed to the internet.

The app just needs this server's base URL entered once during pairing.

## API

- `GET /health` -> `{ ok: true }`
- `POST /rooms/:roomId/sync` body `{ notes: [{ id, ciphertext, iv, updatedAt, deleted }] }`
  -> returns the room's full merged note set
- `WS /ws?room=:roomId` — realtime channel; send `{ type: "push"|"sync", notes: [...] }`,
  receive `{ type: "push"|"push_ack"|"sync_result", notes: [...] }`
