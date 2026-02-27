# Weight Tracker

Cross-platform Flutter app to track body weight and sync entries through Google Drive.

## How sync works

- Sign-in uses Google OAuth 2.0 Authorization Code + PKCE (browser-based).
- Entries are saved as JSON in Google Drive app data space:
  - `weights.json` in `appDataFolder`
- No local database is used.

## Google app registration

1. Open Google Cloud Console.
2. Enable **Google Drive API**.
3. Configure OAuth consent screen.
4. Create OAuth client of type **Desktop app**.
5. Copy the client ID (and secret if provided).

Required scope:

- `https://www.googleapis.com/auth/drive.appdata`

## Run

```bash
flutter run --dart-define=GOOGLE_CLIENT_ID=<your-desktop-client-id>
```

If your Desktop client has a secret, you can also pass:

```bash
--dart-define=GOOGLE_CLIENT_SECRET=<your-client-secret>
```

## Notes

- This app opens your browser for sign-in and listens on a local loopback callback URL (`http://127.0.0.1:<port>/oauth2callback`).
- Current implementation does not support Flutter web target for this auth flow.
- Session tokens are persisted locally to avoid re-authentication on every restart.
