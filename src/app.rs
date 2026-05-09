pub mod api;
pub mod auth;
pub mod config;
pub mod tui;

use anyhow::Result;
use clap::{Parser, Subcommand};

use crate::api::XClient;
use crate::auth::TokenSession;
use crate::config::ConfigStore;

#[derive(Parser, Debug)]
#[command(name = "xui")]
#[command(version)]
#[command(about = "A minimal X API v2 terminal composer using external OAuth 2.0 tokens")]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Save local X API app credentials before running OAuth login.
    Init {
        #[arg(long)]
        client_id: String,
        #[arg(long)]
        client_secret: Option<String>,
        #[arg(long)]
        base_url: Option<String>,
        #[arg(long)]
        timeout_ms: Option<u64>,
    },
    /// Run the OAuth 2.0 PKCE login flow and save tokens locally.
    Login {
        #[arg(long)]
        client_id: Option<String>,
        #[arg(long)]
        client_secret: Option<String>,
        #[arg(long, default_value = auth::DEFAULT_REDIRECT_URI)]
        redirect_uri: String,
        #[arg(long)]
        print_url: bool,
    },
    /// Validate configured credentials against X API v2.
    Doctor,
    /// Post text directly without opening the TUI.
    Post {
        #[arg(required = true)]
        text: Vec<String>,
    },
    /// Open the terminal composer.
    Compose,
}

pub fn run() -> Result<()> {
    let cli = Cli::parse();

    let mut store = ConfigStore::load_default()?;

    match cli.command.unwrap_or(Command::Compose) {
        Command::Init {
            client_id,
            client_secret,
            base_url,
            timeout_ms,
        } => {
            store.initialize(client_id, client_secret, base_url, timeout_ms)?;
            println!("saved configuration to {}", store.path().display());
            println!("next: run `xui login`, then `xui compose`");
        }
        Command::Login {
            client_id,
            client_secret,
            redirect_uri,
            print_url,
        } => {
            let api = api_from_store(&store)?;
            let client_id = client_id
                .or_else(|| store.settings().auth.client_id.clone())
                .ok_or_else(|| anyhow::anyhow!("missing client_id; pass --client-id"))?;
            let client_secret =
                client_secret.or_else(|| store.settings().auth.client_secret.clone());
            let auth_config = auth::login_with_pkce(
                &client_id,
                client_secret.as_deref(),
                &redirect_uri,
                store.settings().api.timeout_ms,
                print_url,
            )?;
            store.persist_auth(auth_config)?;

            let mut session = TokenSession::from_auth_config(store.settings().auth.clone())?;
            let (me, auth_changed) = api.get_authenticated_user(&mut session)?;
            persist_session_if_needed(&mut store, &session, auth_changed)?;
            println!("login complete for @{} ({})", me.username, me.id);
            if let Some(expires_at) = session.token_expires_at() {
                println!("access token expires at: {expires_at}");
            }
        }
        Command::Doctor => {
            let api = api_from_store(&store)?;
            let mut session = TokenSession::from_auth_config(store.settings().auth.clone())?;
            let (me, auth_changed) = api.get_authenticated_user(&mut session)?;
            persist_session_if_needed(&mut store, &session, auth_changed)?;
            println!("authenticated as @{} ({})", me.username, me.id);
            println!("name: {}", me.name);
            if let Some(expires_at) = session.token_expires_at() {
                println!("access token expires at: {expires_at}");
            } else {
                println!("access token expiry: unknown");
            }
        }
        Command::Post { text } => {
            let api = api_from_store(&store)?;
            let mut session = TokenSession::from_auth_config(store.settings().auth.clone())?;
            let text = text.join(" ");
            let (posted, auth_changed) = api.create_post(&mut session, &text)?;
            persist_session_if_needed(&mut store, &session, auth_changed)?;
            println!("posted {}: {}", posted.id, posted.text);
            if let Some(rate_limit) = posted.rate_limit {
                println!(
                    "rate limit remaining: {}/{} reset_at={}",
                    rate_limit.remaining, rate_limit.limit, rate_limit.reset_epoch
                );
            }
        }
        Command::Compose => {
            let api = api_from_store(&store)?;
            let session = TokenSession::from_auth_config(store.settings().auth.clone())?;
            tui::run(api, store, session)?;
        }
    }

    Ok(())
}

fn api_from_store(store: &ConfigStore) -> Result<XClient> {
    XClient::new(
        store.settings().api.base_url.clone(),
        store.settings().api.timeout_ms,
    )
}

fn persist_session_if_needed(
    store: &mut ConfigStore,
    session: &TokenSession,
    auth_changed: bool,
) -> Result<()> {
    if auth_changed {
        store.persist_auth(session.export())?;
    }

    Ok(())
}
