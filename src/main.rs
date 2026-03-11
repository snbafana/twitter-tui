mod api;
mod auth;
mod config;
mod tui;

use anyhow::Result;
use clap::{Parser, Subcommand};

use crate::api::XClient;
use crate::auth::TokenSession;
use crate::config::ConfigStore;

#[derive(Parser, Debug)]
#[command(name = "twitter-tui")]
#[command(about = "A minimal X API v2 terminal composer using external OAuth 2.0 tokens")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
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

fn main() -> Result<()> {
    let cli = Cli::parse();

    let mut store = ConfigStore::load_default()?;
    let api = XClient::new(
        store.settings().api.base_url.clone(),
        store.settings().api.timeout_ms,
    )?;

    match cli.command {
        Command::Login {
            client_id,
            client_secret,
            redirect_uri,
            print_url,
        } => {
            let client_id = client_id
                .or_else(|| store.settings().auth.client_id.clone())
                .ok_or_else(|| {
                    anyhow::anyhow!("missing client_id; pass --client-id or set X_CLIENT_ID")
                })?;
            let client_secret =
                client_secret.or_else(|| store.settings().auth.client_secret.clone());
            let auth_config = auth::login_with_pkce(
                &client_id,
                client_secret.as_deref(),
                &redirect_uri,
                store.settings().api.timeout_ms,
                print_url,
            )?;
            store.update_auth(auth_config);
            store.save()?;

            let mut session = TokenSession::from_auth_config(store.settings().auth.clone())?;
            let me = api.get_authenticated_user(&mut session, &mut store)?;
            println!("login complete for @{} ({})", me.username, me.id);
            if let Some(expires_at) = session.token_expires_at() {
                println!("access token expires at: {expires_at}");
            }
        }
        Command::Doctor => {
            let mut session = TokenSession::from_auth_config(store.settings().auth.clone())?;
            let me = api.get_authenticated_user(&mut session, &mut store)?;
            println!("authenticated as @{} ({})", me.username, me.id);
            println!("name: {}", me.name);
            if let Some(expires_at) = session.token_expires_at() {
                println!("access token expires at: {expires_at}");
            } else {
                println!("access token expiry: unknown");
            }
        }
        Command::Post { text } => {
            let mut session = TokenSession::from_auth_config(store.settings().auth.clone())?;
            let text = text.join(" ");
            let posted = api.create_post(&mut session, &mut store, &text)?;
            println!("posted {}: {}", posted.id, posted.text);
            if let Some(rate_limit) = posted.rate_limit {
                println!(
                    "rate limit remaining: {}/{} reset_at={}",
                    rate_limit.remaining, rate_limit.limit, rate_limit.reset_epoch
                );
            }
        }
        Command::Compose => {
            let session = TokenSession::from_auth_config(store.settings().auth.clone())?;
            tui::run(api, store, session)?;
        }
    }

    Ok(())
}
