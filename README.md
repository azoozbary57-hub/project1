# Notes Sync

A notes app for Windows and Android that syncs between paired devices without
any account or email — devices pair with a one-time code/QR code, and a small
relay server passes end-to-end encrypted note changes between them.

- `app/` — the Flutter app (Windows + Android from one codebase). See `app/README.md`.
- `server/` — the zero-knowledge relay server (Node.js). See `server/README.md`.

## Quick start

```bash
# 1. Run the relay server (reachable from both devices, e.g. on your LAN)
cd server && npm install && npm start

# 2. Generate native platform folders and run the app (needs the Flutter SDK)
cd ../app
flutter create . --platforms=windows,android --org com.example
flutter pub get
flutter run -d windows
```

See `app/README.md` for the required Android manifest tweaks and how pairing works.
