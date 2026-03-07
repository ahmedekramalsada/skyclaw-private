use thiserror::Error;

#[derive(Error, Debug)]
pub enum SkyclawError {
    #[error("Configuration error: {0}")]
    Config(String),

    #[error("Provider error: {0}")]
    Provider(String),

    #[error("Channel error: {0}")]
    Channel(String),

    #[error("Memory error: {0}")]
    Memory(String),

    #[error("Vault error: {0}")]
    Vault(String),

    #[error("Tool execution error: {0}")]
    Tool(String),

    #[error("File transfer error: {0}")]
    FileTransfer(String),

    #[error("Authentication error: {0}")]
    Auth(String),

    #[error("Permission denied: {0}")]
    PermissionDenied(String),

    #[error("Sandbox violation: {0}")]
    SandboxViolation(String),

    #[error("Rate limited: {0}")]
    RateLimited(String),

    #[error("Not found: {0}")]
    NotFound(String),

    #[error("Skill error: {0}")]
    Skill(String),

    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Internal error: {0}")]
    Internal(String),
}
