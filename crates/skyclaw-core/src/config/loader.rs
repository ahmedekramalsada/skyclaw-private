use crate::types::config::SkyclawConfig;
use crate::types::error::SkyclawError;
use std::path::{Path, PathBuf};

/// Discover config file locations in priority order
fn config_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();

    // 1. System config
    paths.push(PathBuf::from("/etc/skyclaw/config.toml"));

    // 2. User config
    if let Some(home) = dirs::home_dir() {
        paths.push(home.join(".skyclaw").join("config.toml"));
    }

    // 3. Workspace config
    paths.push(PathBuf::from("config.toml"));
    paths.push(PathBuf::from("skyclaw.toml"));

    paths
}

/// Load configuration from discovered config files, merging in order
pub fn load_config(explicit_path: Option<&Path>) -> Result<SkyclawConfig, SkyclawError> {
    let mut config_content = String::new();

    if let Some(path) = explicit_path {
        config_content = std::fs::read_to_string(path)
            .map_err(|e| SkyclawError::Config(format!("Failed to read {}: {}", path.display(), e)))?;
    } else {
        for path in config_paths() {
            if path.exists() {
                config_content = std::fs::read_to_string(&path)
                    .map_err(|e| SkyclawError::Config(format!("Failed to read {}: {}", path.display(), e)))?;
                break;
            }
        }
    }

    if config_content.is_empty() {
        return Ok(SkyclawConfig::default());
    }

    // Expand environment variables
    let expanded = super::env::expand_env_vars(&config_content);

    // Try TOML first (native format + ZeroClaw compat)
    if let Ok(config) = toml::from_str::<SkyclawConfig>(&expanded) {
        return Ok(config);
    }

    // Try YAML (OpenClaw compat)
    if let Ok(config) = serde_yaml::from_str::<SkyclawConfig>(&expanded) {
        return Ok(config);
    }

    Err(SkyclawError::Config(
        "Failed to parse config as TOML or YAML".to_string(),
    ))
}

impl Default for SkyclawConfig {
    fn default() -> Self {
        Self {
            skyclaw: Default::default(),
            gateway: Default::default(),
            provider: Default::default(),
            memory: Default::default(),
            vault: Default::default(),
            filestore: Default::default(),
            security: Default::default(),
            heartbeat: Default::default(),
            cron: Default::default(),
            channel: Default::default(),
            tools: Default::default(),
            tunnel: None,
            observability: Default::default(),
        }
    }
}
