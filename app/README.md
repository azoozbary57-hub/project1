# Notes Sync (Flutter — Windows + Android)

A single Flutter codebase for Windows and Android that syncs notes between
paired devices through the relay server in `../server`, with no account or
email required. Pairing is done via a one-time code/QR code; the encryption
key never leaves your devices (see `server/README.md` for how that works).

## ⚠️ One-time setup this environment couldn't do for you

This code was written in a sandbox without the Flutter SDK installed, so the
native platform folders (`android/`, `windows/`, etc.) that `flutter create`
normally generates are **not** included. Before this builds, run, once:

```bash
cd app
flutter create . --platforms=windows,android --org com.example
flutter pub get
```

This fills in `android/` and `windows/` around the existing `lib/` and
`pubspec.yaml` without touching them. Then apply these two required tweaks:

### 1. Android permissions

Add to `android/app/src/main/AndroidManifest.xml` (inside `<manifest>`, above
`<application>`):

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CAMERA" />
```

`INTERNET` is required to reach the relay server at all; `CAMERA` is only
needed for the QR-scan pairing flow.

### 2. Allow plain `http://` to your relay (LAN setups only)

Android blocks cleartext HTTP by default since API 28. If your relay server
runs on your LAN as `http://` (not `https://`), add
`android:usesCleartextTraffic="true"` to the `<application>` tag in the same
`AndroidManifest.xml`. Skip this if your server is behind HTTPS.

Windows has no equivalent restriction.

## Running it

```bash
flutter run -d windows
flutter run              # with an Android device/emulator attached
```

## How pairing works

1. On one device, open the sync icon in the app bar → **إنشاء مجموعة** →
   enter the relay server's URL → **إنشاء**. A QR code and a text code appear.
2. On the other device, open the sync icon → **الانضمام لمجموعة** → enter the
   same server URL → scan the QR (Android) or type the code → **انضمام**.
3. Both devices are now in the same sync "room" and will exchange note
   changes in real time while online, and reconcile automatically the next
   time they're both online after being offline.

Notes work fully offline on a single device even before pairing; pairing only
adds sync on top.

## Project layout

```
lib/
  models/note.dart          Note model
  db/app_database.dart      sqflite (Android) / sqflite_common_ffi (Windows) storage
  crypto/pairing.dart        pairing code generation + roomId/key derivation
  crypto/crypto_service.dart AES-GCM encrypt/decrypt of note contents
  sync/sync_service.dart     REST + WebSocket sync client, LWW merge
  screens/                   UI: notes list, editor, pairing
```
