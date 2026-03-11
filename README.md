# twitter-tui

Minimal terminal composer for the current X API v2.

## Design constraints

- X API v2 only
- OAuth 2.0 user-context tokens only
- Bring your own credentials
- Embedded local PKCE login flow
- Small dependency surface and blocking HTTP

## Configuration

The app reads `~/.config/twitter-tui/config.toml` by default. Override with `TWITTER_TUI_CONFIG`.

```toml
[api]
base_url = "https://api.x.com"
timeout_ms = 10000

[auth]
client_id = "your-oauth2-client-id"
client_secret = "optional-oauth2-client-secret"
access_token = "user-access-token"
refresh_token = "optional-refresh-token"
token_expires_at = 2026-03-11T22:00:00Z
```

Environment variables override file values:

- `X_CLIENT_ID`
- `X_CLIENT_SECRET`
- `X_ACCESS_TOKEN`
- `X_REFRESH_TOKEN`
- `X_TOKEN_EXPIRES_AT`
- `X_API_BASE_URL`
- `X_HTTP_TIMEOUT_MS`

## Full setup flow

You cannot complete the entire setup from the terminal alone. X requires app creation and OAuth configuration in the web-based Developer Console first.

### 1. Create an X developer app

1. Go to [console.x.com](https://console.x.com).
2. Create or open your developer account.
3. Create a new app.
4. Enable OAuth 2.0 for that app.
5. Choose a public/native-style app configuration.
6. Add this callback URL exactly:

```text
http://127.0.0.1:8787/callback
```

7. Enable these scopes:

```text
tweet.read tweet.write users.read offline.access
```

8. Copy the app's `Client ID`.

`offline.access` matters because it allows the app to receive a refresh token, so you do not have to re-authenticate every time the access token expires.

### 2. Open this project locally

```bash
cd /Users/snbafana/Documents/personal/workspace/twitter-tui
```

### 3. Run login

```bash
cargo run -- login --client-id YOUR_CLIENT_ID
```

What happens next:

1. The app generates a PKCE verifier, challenge, and state.
2. The app starts a local callback listener on `127.0.0.1:8787`.
3. The app opens your browser to X's OAuth approval page.
4. You sign in and approve your own app.
5. X redirects back to `http://127.0.0.1:8787/callback`.
6. The app exchanges the authorization code for an `access_token` and optional `refresh_token`.
7. The app saves the token bundle to `~/.config/twitter-tui/config.toml`.

### 4. Verify the login

```bash
cargo run -- doctor
```

This calls `GET /2/users/me` and confirms that the saved token is a valid OAuth 2.0 user-context token.

### 5. Post from the terminal

One-off post:

```bash
cargo run -- post "hello from the terminal"
```

Interactive composer:

```bash
cargo run -- compose
```

### 6. Common setup failures

- The callback URL in X does not exactly match `http://127.0.0.1:8787/callback`.
- The app is missing `tweet.write` or `users.read`.
- Port `8787` is already in use by another process.
- You approved a different X app than the one matching your `Client ID`.
- You skipped `offline.access`, so no refresh token was issued.

## Commands

```bash
cargo run -- login --client-id YOUR_CLIENT_ID --client-secret YOUR_CLIENT_SECRET
cargo run -- doctor
cargo run -- post "hello from the terminal"
cargo run -- compose
```

## Login flow

The easiest supported path is:

```bash
cargo run -- login --client-id YOUR_CLIENT_ID --client-secret YOUR_CLIENT_SECRET
```

Before running that command, configure this callback URL in your X app:

```text
http://127.0.0.1:8787/callback
```

The app will open your browser, complete OAuth 2.0 PKCE, save the token bundle locally, and then you can use `doctor`, `post`, or `compose`.
