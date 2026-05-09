# XUI

Minimal terminal composer for the current X API v2.

## Design constraints

- X API v2 only
- OAuth 2.0 user-context tokens only
- Bring your own credentials
- Embedded local PKCE login flow
- Small dependency surface and blocking HTTP

## Configuration

On macOS, the app stores credentials in:

```text
~/Library/Application Support/com.codex.twitter-tui/config.toml
```

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

## Full setup flow

You cannot complete the entire setup from the terminal alone. X requires app creation and OAuth configuration in the web-based Developer Console first.

XUI is bring-your-own-auth. It ships no shared developer account, no access token, and no app secret. Each user creates an X developer app, enters that app's OAuth 2.0 Client ID and optional Client Secret locally, then authorizes their own X account through X's OAuth screen.

### 1. Create an X developer app

1. Go to [console.x.com](https://console.x.com).
2. Create or open your developer account.
3. Create a new app.
4. Enable OAuth 2.0 for that app.
5. Copy the app's `Client ID`. If X also issued a `Client Secret` for your app, keep that too.
6. Add this callback URL exactly:

```text
http://127.0.0.1:8787/callback
```

7. Enable these scopes:

```text
tweet.read tweet.write users.read offline.access
```

`offline.access` matters because it allows the app to receive a refresh token, so you do not have to re-authenticate every time the access token expires.

### 2. Open this project locally

```bash
cd /Users/snbafana/Documents/personal/workspace/twitter-tui
```

### 3. Build and install XUI

Build the release binary:

```bash
cargo build --release --bin xui
```

Install it into a user-local bin directory:

```bash
mkdir -p ~/.local/bin
cp target/release/xui ~/.local/bin/xui
chmod 755 ~/.local/bin/xui
```

If `~/.local/bin` is not already on your PATH, add it for zsh:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Confirm the install:

```bash
xui --version
```

### 4. Initialize credentials

```bash
xui init --client-id YOUR_CLIENT_ID --client-secret YOUR_CLIENT_SECRET
```

If your app does not use a client secret, omit `--client-secret`.

This writes the local config file and preserves the user's own X API app credentials on their machine. Tokens are still created only after OAuth login.

### 5. Run login

```bash
xui login
```

From a source checkout, use:

```bash
cargo run -- login
```

What happens next:

1. The app generates a PKCE verifier, challenge, and state.
2. The app starts a local callback listener on `127.0.0.1:8787`.
3. The app opens your browser to X's OAuth approval page.
4. You sign in and approve your own app.
5. X redirects back to `http://127.0.0.1:8787/callback`.
6. The app exchanges the authorization code for an `access_token` and optional `refresh_token`.
7. The app saves the token bundle to `~/Library/Application Support/com.codex.twitter-tui/config.toml`.

### 6. Verify the login

```bash
xui doctor
```

This calls `GET /2/users/me` and confirms that the saved token is a valid OAuth 2.0 user-context token.

### 7. Post from the terminal

One-off post:

```bash
xui post "hello from the terminal"
```

Interactive composer:

```bash
xui
```

Equivalent explicit command:

```bash
xui compose
```

### 8. Common setup failures

- The callback URL in X does not exactly match `http://127.0.0.1:8787/callback`.
- The app is missing `tweet.write` or `users.read`.
- Port `8787` is already in use by another process.
- You approved a different X app than the one matching your `Client ID`.
- You skipped `offline.access`, so no refresh token was issued.

## Commands

```bash
xui --version
xui init --client-id YOUR_CLIENT_ID --client-secret YOUR_CLIENT_SECRET
xui login
xui doctor
xui
xui post "hello from the terminal"
xui compose
```

From source:

```bash
cargo run -- --version
cargo run -- init --client-id YOUR_CLIENT_ID --client-secret YOUR_CLIENT_SECRET
cargo run -- login
cargo run -- doctor
cargo run
cargo run -- post "hello from the terminal"
cargo run -- compose
```

The legacy `twitter-tui` binary is still built for compatibility, but the default source run target is `xui`.

## Bring-your-own auth

XUI uses OAuth 2.0 Authorization Code Flow with PKCE. The user supplies only their X developer app's `Client ID` and optional `Client Secret`:

```bash
xui init --client-id YOUR_CLIENT_ID --client-secret YOUR_CLIENT_SECRET
xui login
```

`xui login` starts a local callback listener on `127.0.0.1:8787`, opens the X authorization URL, and waits for X to redirect back with an authorization code. XUI exchanges that short-lived code for an access token and, when `offline.access` is enabled, a refresh token. Those tokens are written only to the user's local config file.

For public/native-client use, users can omit `--client-secret`:

```bash
xui init --client-id YOUR_CLIENT_ID
```

The required app scopes are:

```text
tweet.read tweet.write users.read offline.access
```

`tweet.write` is what allows posting, `users.read` is used by `doctor` and account display, and `offline.access` is what lets X issue a refresh token so the user does not have to log in again every two hours.

## Versioning and releases

The app version comes from `Cargo.toml`:

```toml
[package]
version = "0.1.0"
```

`xui --version` prints that same version through Clap. To cut a release:

```bash
cargo test
cargo clippy --all-targets -- -D warnings
git tag v0.1.0
git push origin v0.1.0
```

## Release Archives

For distribution, build the terminal binary and attach it to a GitHub Release:

```bash
cargo build --release --bin xui
```

The binary is `target/release/xui`.
