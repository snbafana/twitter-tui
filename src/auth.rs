use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration as StdDuration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use chrono::{DateTime, Duration, Utc};
use rand::distr::{Alphanumeric, SampleString};
use reqwest::blocking::Client;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use url::{Url, form_urlencoded};

use crate::config::AuthConfig;

pub const DEFAULT_REDIRECT_URI: &str = "http://127.0.0.1:8787/callback";
const AUTHORIZE_URL: &str = "https://x.com/i/oauth2/authorize";
const TOKEN_URL: &str = "https://api.x.com/2/oauth2/token";
const DEFAULT_SCOPES: &str = "tweet.read tweet.write users.read offline.access";

#[derive(Debug, Clone)]
pub struct TokenSession {
    client_id: String,
    client_secret: Option<String>,
    access_token: String,
    refresh_token: Option<String>,
    token_expires_at: Option<DateTime<Utc>>,
}

impl TokenSession {
    pub fn from_auth_config(config: AuthConfig) -> Result<Self> {
        let client_id = config
            .client_id
            .ok_or_else(|| anyhow!("missing client_id; set X_CLIENT_ID or auth.client_id"))?;
        let access_token = config.access_token.ok_or_else(|| {
            anyhow!("missing access_token; set X_ACCESS_TOKEN or auth.access_token")
        })?;

        Ok(Self {
            client_id,
            client_secret: config.client_secret,
            access_token,
            refresh_token: config.refresh_token,
            token_expires_at: config.token_expires_at,
        })
    }

    pub fn access_token(&self) -> &str {
        &self.access_token
    }

    pub fn token_expires_at(&self) -> Option<DateTime<Utc>> {
        self.token_expires_at
    }

    pub fn can_refresh(&self) -> bool {
        self.refresh_token.is_some()
    }

    pub fn should_refresh(&self) -> bool {
        self.token_expires_at
            .map(|expires_at| expires_at <= Utc::now() + Duration::seconds(60))
            .unwrap_or(false)
    }

    pub fn refresh_if_needed(&mut self, client: &Client, base_url: &str) -> Result<bool> {
        if self.should_refresh() {
            self.refresh(client, base_url)?;
            return Ok(true);
        }
        Ok(false)
    }

    pub fn refresh(&mut self, client: &Client, base_url: &str) -> Result<()> {
        let refresh_token = self
            .refresh_token
            .clone()
            .ok_or_else(|| anyhow!("token refresh requested but no refresh token is configured"))?;

        let url = format!("{}/2/oauth2/token", base_url.trim_end_matches('/'));
        let response = client
            .post(url)
            .maybe_basic_auth(self.client_id.as_str(), self.client_secret.as_deref())
            .form(&[
                ("refresh_token", refresh_token.as_str()),
                ("grant_type", "refresh_token"),
                ("client_id", self.client_id.as_str()),
            ])
            .send()?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().unwrap_or_default();
            bail!("refresh failed with {}: {}", status, body);
        }

        let payload: RefreshTokenResponse = response.json()?;
        self.access_token = payload.access_token;
        if let Some(refresh_token) = payload.refresh_token {
            self.refresh_token = Some(refresh_token);
        }
        self.token_expires_at = payload
            .expires_in
            .map(|expires_in| Utc::now() + Duration::seconds(expires_in as i64));
        Ok(())
    }

    pub fn export(&self) -> AuthConfig {
        AuthConfig {
            client_id: Some(self.client_id.clone()),
            client_secret: self.client_secret.clone(),
            access_token: Some(self.access_token.clone()),
            refresh_token: self.refresh_token.clone(),
            token_expires_at: self.token_expires_at,
        }
    }
}

#[derive(Debug, Deserialize)]
struct RefreshTokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct AuthorizationCodeTokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: Option<u64>,
}

pub fn login_with_pkce(
    client_id: &str,
    client_secret: Option<&str>,
    redirect_uri: &str,
    timeout_ms: u64,
    print_url: bool,
) -> Result<AuthConfig> {
    let redirect = Url::parse(redirect_uri).context("invalid redirect URI")?;
    let host = redirect
        .host_str()
        .ok_or_else(|| anyhow!("redirect URI must include a host"))?;
    let port = redirect
        .port_or_known_default()
        .ok_or_else(|| anyhow!("redirect URI must include a port"))?;
    if host != "127.0.0.1" && host != "localhost" {
        bail!("redirect URI host must be 127.0.0.1 or localhost for local login");
    }

    let state = random_token(32);
    let code_verifier = random_token(64);
    let code_challenge = pkce_challenge(&code_verifier);
    let authorize_url = build_authorize_url(client_id, redirect_uri, &state, &code_challenge)?;

    let listener = TcpListener::bind((host, port))
        .with_context(|| format!("failed to bind callback listener on {host}:{port}"))?;
    listener
        .set_nonblocking(true)
        .context("failed to configure callback listener")?;

    println!("Open this callback URL in your X app settings: {redirect_uri}");
    if print_url || webbrowser::open(authorize_url.as_str()).is_err() {
        println!("Open this authorization URL in your browser:");
        println!("{authorize_url}");
    } else {
        println!("Browser opened for X authorization.");
    }

    let callback = wait_for_callback(&listener, StdDuration::from_secs(180))?;
    let returned_state = callback
        .state
        .ok_or_else(|| anyhow!("missing state in callback"))?;
    if returned_state != state {
        bail!("state mismatch in callback");
    }
    let code = callback
        .code
        .ok_or_else(|| anyhow!("missing code in callback"))?;

    let http = Client::builder()
        .timeout(StdDuration::from_millis(timeout_ms))
        .build()
        .context("failed to build HTTP client")?;
    let response = http
        .post(TOKEN_URL)
        .maybe_basic_auth(client_id, client_secret)
        .form(&[
            ("code", code.as_str()),
            ("grant_type", "authorization_code"),
            ("client_id", client_id),
            ("redirect_uri", redirect_uri),
            ("code_verifier", code_verifier.as_str()),
        ])
        .send()
        .context("failed to exchange authorization code")?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().unwrap_or_default();
        bail!("token exchange failed with {}: {}", status, body);
    }

    let payload: AuthorizationCodeTokenResponse =
        response.json().context("failed to decode token response")?;

    Ok(AuthConfig {
        client_id: Some(client_id.to_string()),
        client_secret: client_secret.map(str::to_string),
        access_token: Some(payload.access_token),
        refresh_token: payload.refresh_token,
        token_expires_at: payload
            .expires_in
            .map(|expires_in| Utc::now() + Duration::seconds(expires_in as i64)),
    })
}

fn build_authorize_url(
    client_id: &str,
    redirect_uri: &str,
    state: &str,
    code_challenge: &str,
) -> Result<Url> {
    Url::parse_with_params(
        AUTHORIZE_URL,
        &[
            ("response_type", "code"),
            ("client_id", client_id),
            ("redirect_uri", redirect_uri),
            ("scope", DEFAULT_SCOPES),
            ("state", state),
            ("code_challenge", code_challenge),
            ("code_challenge_method", "S256"),
        ],
    )
    .context("failed to build authorize URL")
}

fn wait_for_callback(listener: &TcpListener, timeout: StdDuration) -> Result<CallbackPayload> {
    let deadline = Instant::now() + timeout;
    loop {
        match listener.accept() {
            Ok((stream, _)) => return handle_callback(stream),
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                if Instant::now() >= deadline {
                    bail!("timed out waiting for OAuth callback");
                }
                std::thread::sleep(StdDuration::from_millis(100));
            }
            Err(err) => return Err(err).context("failed to accept callback connection"),
        }
    }
}

fn handle_callback(mut stream: TcpStream) -> Result<CallbackPayload> {
    let mut first_line = String::new();
    {
        let mut reader = BufReader::new(&mut stream);
        reader
            .read_line(&mut first_line)
            .context("failed to read callback request")?;
    }

    let target = first_line
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| anyhow!("malformed callback request"))?;
    let url = Url::parse(&format!("http://localhost{target}")).context("invalid callback URL")?;
    let params = form_urlencoded::parse(url.query().unwrap_or_default().as_bytes())
        .into_owned()
        .collect::<std::collections::HashMap<String, String>>();

    let payload = CallbackPayload {
        code: params.get("code").cloned(),
        state: params.get("state").cloned(),
        error: params.get("error").cloned(),
        error_description: params.get("error_description").cloned(),
    };

    let (status_line, body) = if let Some(error) = &payload.error {
        (
            "HTTP/1.1 400 Bad Request\r\n",
            format!(
                "X authorization failed: {} {}",
                error,
                payload.error_description.clone().unwrap_or_default()
            ),
        )
    } else {
        (
            "HTTP/1.1 200 OK\r\n",
            "Authorization complete. You can return to twitter-tui.".to_string(),
        )
    };
    let response = format!(
        "{status_line}Content-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    stream
        .write_all(response.as_bytes())
        .context("failed to write callback response")?;

    if let Some(error) = &payload.error {
        bail!(
            "authorization denied: {} {}",
            error,
            payload.error_description.unwrap_or_default()
        );
    }

    Ok(payload)
}

fn random_token(len: usize) -> String {
    Alphanumeric.sample_string(&mut rand::rng(), len)
}

fn pkce_challenge(verifier: &str) -> String {
    let digest = Sha256::digest(verifier.as_bytes());
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest)
}

struct CallbackPayload {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
    error_description: Option<String>,
}

trait RequestBuilderExt {
    fn maybe_basic_auth(self, username: &str, password: Option<&str>) -> Self;
}

impl RequestBuilderExt for reqwest::blocking::RequestBuilder {
    fn maybe_basic_auth(self, username: &str, password: Option<&str>) -> Self {
        if let Some(password) = password {
            self.basic_auth(username, Some(password))
        } else {
            self
        }
    }
}
