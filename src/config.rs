use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow};
use chrono::{DateTime, Utc};
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    #[serde(default)]
    pub api: ApiConfig,
    #[serde(default)]
    pub auth: AuthConfig,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            api: ApiConfig::default(),
            auth: AuthConfig::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiConfig {
    #[serde(default = "default_base_url")]
    pub base_url: String,
    #[serde(default = "default_timeout_ms")]
    pub timeout_ms: u64,
}

impl Default for ApiConfig {
    fn default() -> Self {
        Self {
            base_url: default_base_url(),
            timeout_ms: default_timeout_ms(),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AuthConfig {
    pub client_id: Option<String>,
    pub client_secret: Option<String>,
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    pub token_expires_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone)]
pub struct ConfigStore {
    path: PathBuf,
    settings: AppConfig,
}

impl ConfigStore {
    pub fn load_default() -> Result<Self> {
        let path = config_path()?;
        let settings = if path.exists() {
            let raw = fs::read_to_string(&path)
                .with_context(|| format!("failed to read config file {}", path.display()))?;
            toml::from_str::<AppConfig>(&raw)
                .with_context(|| format!("failed to parse config file {}", path.display()))?
        } else {
            AppConfig::default()
        };

        Ok(Self { path, settings })
    }

    pub fn settings(&self) -> &AppConfig {
        &self.settings
    }

    pub fn persist_auth(&mut self, auth: AuthConfig) -> Result<()> {
        self.settings.auth = auth;
        self.save_file()
    }

    fn save_file(&self) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).with_context(|| {
                format!("failed to create config directory {}", parent.display())
            })?;
        }

        let raw = toml::to_string_pretty(&self.settings).context("failed to encode config")?;
        write_private_file(&self.path, &raw)?;
        Ok(())
    }
}

fn config_path() -> Result<PathBuf> {
    let project_dirs = ProjectDirs::from("com", "codex", "twitter-tui")
        .ok_or_else(|| anyhow!("failed to determine a configuration directory"))?;
    Ok(project_dirs.config_dir().join("config.toml"))
}

fn write_private_file(path: &Path, contents: &str) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;

        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(path)
            .with_context(|| format!("failed to open {}", path.display()))?;
        file.write_all(contents.as_bytes())
            .with_context(|| format!("failed to write {}", path.display()))?;
        return Ok(());
    }

    #[cfg(not(unix))]
    {
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(path)
            .with_context(|| format!("failed to open {}", path.display()))?;
        file.write_all(contents.as_bytes())
            .with_context(|| format!("failed to write {}", path.display()))?;
        Ok(())
    }
}

fn default_base_url() -> String {
    "https://api.x.com".to_string()
}

fn default_timeout_ms() -> u64 {
    10_000
}
