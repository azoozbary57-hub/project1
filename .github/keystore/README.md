This is a fixed **debug**-only Android signing keystore (alias `androiddebugkey`,
password `android` — the same well-known defaults the Android SDK itself uses
for its auto-generated debug keystore). It is intentionally committed: it is
not used for the Play Store and holds no secret value, but committing it
keeps every CI build signed with the *same* key.

Without this, each GitHub Actions run starts a fresh container with no
`~/.android/debug.keystore`, so Gradle auto-generates a new one per build —
meaning every release APK has a different signing certificate, and Android
refuses to install an update over the previous install ("App not installed").
The build workflow copies this file to `~/.android/debug.keystore` before
building so every APK is signed identically and updates install cleanly.
