# XUI macOS

Native SwiftUI shell for XUI.

This target is intentionally separate from the existing Rust CLI/TUI. The first screen is the composer, and the CLI stays available while the native OAuth/API layer is ported.

## Run

```bash
cd macos/XUI
swift run
```

## Build and Test

```bash
cd macos/XUI
swift build
swift test
```

## Current State

- Composer-first SwiftUI window.
- Native text editor, status row, character count, send/clear commands.
- Settings panel for OAuth Client ID, optional Client Secret, API base URL, and callback URL.
- Client Secret and OAuth token slots are Keychain-backed.
- Native API client boundary for `GET /2/users/me` and `POST /2/tweets`.
- Login action opens the X authorization URL, captures the localhost callback, exchanges the authorization code, stores tokens in Keychain, and loads `GET /2/users/me`.
- Send action refreshes near-expired tokens when possible, reads an access token from Keychain, and posts through `URLSession`.
- X API error payloads are surfaced as concise status messages instead of raw response bodies.
- Login strategy check distinguishes localhost, custom scheme, web associated-domain, and invalid callback modes.
- Focused unit tests cover OAuth authorization URL construction, PKCE output shape, callback strategy selection, localhost callback parsing, form encoding, refresh timing, API request shape, response decoding, and X error payload handling.

## Next Native Milestones

1. Run the flow against a real X OAuth app and confirm callback/token exchange behavior.
2. Improve token-exchange error display to match the API client error parser.
3. Decide whether to keep localhost as the default native callback mode or add a bundled custom URL scheme later.
