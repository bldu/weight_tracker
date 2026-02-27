# Weight Tracker

Cross-platform Flutter app to track body weight and sync entries through Google Drive.

## How sync works

- macOS/Linux: Google OAuth 2.0 Authorization Code + PKCE (browser-based loopback).
- Android: native Google Sign-In.
- Entries are saved as JSON in Google Drive app data space:
  - `weights.json` in `appDataFolder`
- No local database is used.

## Google app registration

1. Open Google Cloud Console.
2. Enable **Google Drive API**.
3. Configure OAuth consent screen.
4. Create OAuth clients:
   - **Desktop app** client (for macOS/Linux).
   - **Android** client (for Android package + SHA-1).
5. Copy the Desktop client ID (and secret if provided).

Required scope:

- `https://www.googleapis.com/auth/drive.appdata`

## Run (macOS/Linux)

```bash
flutter run --dart-define=GOOGLE_CLIENT_ID=<your-desktop-client-id>
```

If your Desktop client has a secret, you can also pass:

```bash
--dart-define=GOOGLE_CLIENT_SECRET=<your-client-secret>
```

## Run (Android)

```bash
flutter run -d android
```

Android uses the native sign-in SDK and does not use `GOOGLE_CLIENT_ID` dart-define.

## Notes

- Desktop sign-in opens your browser and listens on a local loopback callback URL (`http://127.0.0.1:<port>/oauth2callback`).
- Android requires a valid Android OAuth client for your app id and signing certificate SHA-1.
- Current implementation does not support Flutter web target for this auth flow.
- Desktop session tokens are persisted locally to avoid re-authentication on every restart.
