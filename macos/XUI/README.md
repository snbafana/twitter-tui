# XUI macOS

Native SwiftUI shell for XUI.

This target is intentionally separate from the existing Rust CLI/TUI. The first screen is the composer, and the CLI stays available while the native OAuth/API layer is ported.

## Run

```bash
cd macos/XUI
swift run
```

`swift run` is useful for development, but it launches a raw SwiftPM executable. For normal typing/focus behavior, build and open the app bundle instead:

```bash
cd macos/XUI
./scripts/build-app.sh
open build/XUI.app
```

This creates `macos/XUI/build/XUI.app`, a local foreground macOS app bundle. It is not a DMG and is not committed.

## Build and Test

```bash
cd macos/XUI
swift build
swift test
```

## Smoke Validation

The native app can be launched without X credentials. This verifies the SwiftUI app boots into the composer and does not exercise OAuth:

```bash
cd macos/XUI
swift run
```

Expected first-run state:

- The main window opens directly to the composer.
- The app appears as `XUI` in the macOS app switcher and accepts keyboard focus like a normal app.
- The header says `XUI` and `Bring your own X auth`.
- The composer toolbar has text style controls (`B`, `I`, `Serif`) and an `Image` attachment button.
- Images can also be dragged onto the composer; attached images appear as draft thumbnails with an `x` remove control.
- `Settings` opens the local OAuth app settings; `Done` saves and closes the sheet.
- `Log In` should fail locally until a Client ID is configured; it should not open a browser with missing setup.
- `Send` stays disabled until there is text and a valid token.

Text styling uses Unicode styled characters because X post text is plain text, not Markdown or rich text. Image posting follows the X API media flow: upload the image to `POST /2/media/upload`, then attach the returned media ID to `POST /2/tweets`.

Live OAuth validation still requires a real X developer app configured with `http://127.0.0.1:8787/callback` and scopes `tweet.read tweet.write users.read offline.access`.

## Current State

- Composer-first SwiftUI window.
- Native text editor, status row, character count, send/clear commands.
- Unicode text styling controls for bold, italic, and serif draft transforms.
- Image picker and drag/drop attachment for JPG, PNG, WebP, BMP, and TIFF files up to 5 MB.
- Draft image tray with up to 4 thumbnails and per-image `x` removal.
- Minimal Settings sheet for OAuth Client ID, optional Client Secret, API base URL, and callback URL.
- Client Secret and OAuth token slots are Keychain-backed.
- First-run setup validation catches missing Client ID, invalid API base URL, and unsupported callback URLs before opening the browser.
- Native API client boundary for `GET /2/users/me` and `POST /2/tweets`.
- Native media upload boundary for `POST /2/media/upload`, with uploaded media attached to posts by `media_ids`.
- Login action opens the X authorization URL, captures the localhost callback, exchanges the authorization code, stores tokens in Keychain, and loads `GET /2/users/me`.
- Send action refreshes near-expired tokens when possible, reads an access token from Keychain, and posts through `URLSession`.
- X API and token-exchange error payloads are surfaced as concise status messages instead of raw response bodies.
- Login strategy check distinguishes localhost, custom scheme, web associated-domain, and invalid callback modes.
- Focused unit tests cover settings setup validation, OAuth authorization URL construction, PKCE output shape, callback strategy selection, localhost callback parsing, form encoding, refresh timing, token response decoding, API request shape, response decoding, and X error payload handling.

## Next Native Milestones

1. Run the flow against a real X OAuth app and confirm callback/token exchange behavior.
2. Decide whether to keep localhost as the default native callback mode or add a bundled custom URL scheme later.
