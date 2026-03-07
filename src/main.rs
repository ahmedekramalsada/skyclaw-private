use clap::{Parser, Subcommand};
use anyhow::Result;

#[derive(Parser)]
#[command(name = "skyclaw")]
#[command(about = "Cloud-native Rust AI agent runtime")]
#[command(version)]
struct Cli {
    /// Path to config file
    #[arg(short, long)]
    config: Option<String>,

    /// Runtime mode: cloud, local, or auto
    #[arg(long, default_value = "auto")]
    mode: String,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the SkyClaw gateway daemon
    Start {
        /// Enable GUI mode (headed browser, desktop interaction)
        #[arg(long)]
        gui: bool,
    },
    /// Interactive CLI chat with the agent
    Chat,
    /// Show gateway status, connected channels, provider health
    Status,
    /// Manage skills
    Skill {
        #[command(subcommand)]
        command: SkillCommands,
    },
    /// Manage configuration
    Config {
        #[command(subcommand)]
        command: ConfigCommands,
    },
    /// Migrate from OpenClaw or ZeroClaw
    Migrate {
        /// Source platform: openclaw or zeroclaw
        #[arg(long)]
        from: String,
        /// Path to source workspace
        path: String,
    },
    /// Show version information
    Version,
}

#[derive(Subcommand)]
enum SkillCommands {
    /// List installed skills
    List,
    /// Show skill details
    Info { name: String },
    /// Install a skill from a path
    Install { path: String },
}

#[derive(Subcommand)]
enum ConfigCommands {
    /// Validate the current configuration
    Validate,
    /// Show resolved configuration
    Show,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .json()
        .init();

    // Load configuration
    let config_path = cli.config.as_ref().map(std::path::Path::new);
    let config = skyclaw_core::config::load_config(config_path)?;

    tracing::info!(mode = %cli.mode, "SkyClaw starting");

    match cli.command {
        Commands::Start { gui } => {
            tracing::info!(gui = gui, "Starting SkyClaw gateway");
            // TODO: Initialize and start gateway with all configured channels
            println!("SkyClaw gateway starting...");
            println!("Mode: {}", cli.mode);
            println!("GUI: {}", gui);
            println!("Gateway: {}:{}", config.gateway.host, config.gateway.port);

            // Keep running until interrupted
            tokio::signal::ctrl_c().await?;
            tracing::info!("Shutting down gracefully");
        }
        Commands::Chat => {
            println!("SkyClaw interactive chat");
            println!("Type 'exit' to quit.");
            // TODO: Start CLI channel directly
        }
        Commands::Status => {
            println!("SkyClaw Status");
            println!("  Mode: {}", config.skyclaw.mode);
            println!("  Gateway: {}:{}", config.gateway.host, config.gateway.port);
            println!("  Provider: {}", config.provider.name.as_deref().unwrap_or("not configured"));
            println!("  Memory: {}", config.memory.backend);
            println!("  Vault: {}", config.vault.backend);
        }
        Commands::Skill { command } => match command {
            SkillCommands::List => {
                println!("Installed skills:");
                // TODO: List skills from registry
            }
            SkillCommands::Info { name } => {
                println!("Skill info: {}", name);
                // TODO: Show skill details
            }
            SkillCommands::Install { path } => {
                println!("Installing skill from: {}", path);
                // TODO: Install skill
            }
        },
        Commands::Config { command } => match command {
            ConfigCommands::Validate => {
                println!("Configuration valid.");
                println!("  Gateway: {}:{}", config.gateway.host, config.gateway.port);
                println!("  Provider: {}", config.provider.name.as_deref().unwrap_or("none"));
                println!("  Memory backend: {}", config.memory.backend);
                println!("  Channels: {}", config.channel.len());
            }
            ConfigCommands::Show => {
                let output = toml::to_string_pretty(&config)?;
                println!("{}", output);
            }
        },
        Commands::Migrate { from, path } => {
            println!("Migrating from {} at {}", from, path);
            // TODO: Run migration
        }
        Commands::Version => {
            println!("skyclaw {}", env!("CARGO_PKG_VERSION"));
            println!("Cloud-native Rust AI agent runtime");
        }
    }

    Ok(())
}
