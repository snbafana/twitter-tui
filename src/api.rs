use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use reqwest::Method;
use reqwest::blocking::{Client, RequestBuilder, Response};
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderValue};
use serde::{Deserialize, Serialize};

use crate::auth::TokenSession;
use crate::config::ConfigStore;

#[derive(Debug, Clone)]
pub struct XClient {
    http: Client,
    base_url: String,
}

impl XClient {
    pub fn new(base_url: String, timeout_ms: u64) -> Result<Self> {
        let mut default_headers = HeaderMap::new();
        default_headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));

        let http = Client::builder()
            .default_headers(default_headers)
            .timeout(Duration::from_millis(timeout_ms))
            .build()
            .context("failed to build HTTP client")?;

        Ok(Self { http, base_url })
    }

    pub fn get_authenticated_user(
        &self,
        session: &mut TokenSession,
        store: &mut ConfigStore,
    ) -> Result<AuthenticatedUser> {
        let response = self.send_with_refresh(session, store, |client, token| {
            client
                .request(Method::GET, self.url("/2/users/me"))
                .query(&[("user.fields", "created_at,verified")])
                .header(AUTHORIZATION, bearer_header(token))
        })?;

        parse_json::<UserEnvelope>(response).map(|payload| payload.data)
    }

    pub fn create_post(
        &self,
        session: &mut TokenSession,
        store: &mut ConfigStore,
        text: &str,
    ) -> Result<CreatePostResult> {
        let body = CreatePostBody {
            text: text.to_string(),
        };

        let response = self.send_with_refresh(session, store, |client, token| {
            client
                .request(Method::POST, self.url("/2/tweets"))
                .header(AUTHORIZATION, bearer_header(token))
                .json(&body)
        })?;

        let rate_limit = rate_limit_from_headers(response.headers());
        let payload = parse_json::<CreatePostEnvelope>(response)?;

        Ok(CreatePostResult {
            id: payload.data.id,
            text: payload.data.text,
            rate_limit,
        })
    }

    fn send_with_refresh<F>(
        &self,
        session: &mut TokenSession,
        store: &mut ConfigStore,
        request_builder: F,
    ) -> Result<Response>
    where
        F: Fn(&Client, &str) -> RequestBuilder,
    {
        if session.refresh_if_needed(&self.http, &self.base_url)? {
            store.update_auth(session.export());
            store.save()?;
        }

        let response = request_builder(&self.http, session.access_token()).send()?;
        if response.status() != reqwest::StatusCode::UNAUTHORIZED || !session.can_refresh() {
            return ensure_success(response);
        }

        session.refresh(&self.http, &self.base_url)?;
        store.update_auth(session.export());
        store.save()?;
        let retry = request_builder(&self.http, session.access_token()).send()?;
        ensure_success(retry)
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.base_url.trim_end_matches('/'), path)
    }
}

#[derive(Debug, Clone)]
pub struct CreatePostResult {
    pub id: String,
    pub text: String,
    pub rate_limit: Option<RateLimit>,
}

#[derive(Debug, Clone)]
pub struct RateLimit {
    pub limit: u32,
    pub remaining: u32,
    pub reset_epoch: i64,
}

#[derive(Debug, Deserialize)]
struct UserEnvelope {
    data: AuthenticatedUser,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AuthenticatedUser {
    pub id: String,
    pub name: String,
    pub username: String,
}

#[derive(Debug, Serialize)]
struct CreatePostBody {
    text: String,
}

#[derive(Debug, Deserialize)]
struct CreatePostEnvelope {
    data: CreatePostData,
}

#[derive(Debug, Deserialize)]
struct CreatePostData {
    id: String,
    text: String,
}

#[derive(Debug, Deserialize)]
struct ApiErrors {
    errors: Vec<ApiError>,
}

#[derive(Debug, Deserialize)]
struct ApiError {
    title: Option<String>,
    detail: Option<String>,
    status: Option<u16>,
    #[serde(rename = "type")]
    type_url: Option<String>,
}

fn parse_json<T: for<'de> Deserialize<'de>>(response: Response) -> Result<T> {
    response
        .json::<T>()
        .context("failed to decode JSON response")
}

fn ensure_success(response: Response) -> Result<Response> {
    if response.status().is_success() {
        return Ok(response);
    }

    let status = response.status();
    let body = response.text().unwrap_or_default();

    if let Ok(api_errors) = serde_json::from_str::<ApiErrors>(&body) {
        if let Some(error) = api_errors.errors.into_iter().next() {
            let title = error.title.unwrap_or_else(|| "X API error".to_string());
            let detail = error.detail.unwrap_or_else(|| body.clone());
            let code = error
                .status
                .map(|value| value.to_string())
                .unwrap_or_else(|| status.as_u16().to_string());
            let kind = error.type_url.unwrap_or_default();
            bail!("{title} ({code}) {kind} {detail}");
        }
    }

    Err(anyhow!("request failed with {}: {}", status, body))
}

fn bearer_header(token: &str) -> String {
    format!("Bearer {token}")
}

fn rate_limit_from_headers(headers: &reqwest::header::HeaderMap) -> Option<RateLimit> {
    let parse_u32 = |name| headers.get(name)?.to_str().ok()?.parse::<u32>().ok();
    let parse_i64 = |name| headers.get(name)?.to_str().ok()?.parse::<i64>().ok();

    Some(RateLimit {
        limit: parse_u32("x-rate-limit-limit")?,
        remaining: parse_u32("x-rate-limit-remaining")?,
        reset_epoch: parse_i64("x-rate-limit-reset")?,
    })
}
