# ADR-001: Rust Workspace with Multi-Crate Structure

## Status: Proposed

## Context
SkyClaw is a complex system with 12+ subsystems (channels, providers, memory, tools, etc.). We need a code organization strategy that enables:
- Independent compilation of subsystems
- Clear dependency boundaries
- Feature-flag control over optional components
- Fast incremental builds during development

## Decision
Use a Cargo workspace with 13 crates:
- `skyclaw-core`: Trait definitions + shared types (zero external deps beyond serde/async-trait)
- `skyclaw-gateway`: axum-based gateway server
- `skyclaw-agent`: Agent runtime loop
- `skyclaw-providers`: AI provider implementations
- `skyclaw-channels`: Messaging channel implementations
- `skyclaw-memory`: Memory backend implementations
- `skyclaw-vault`: Secrets management
- `skyclaw-tools`: Built-in tool implementations
- `skyclaw-skills`: Skill loading & management
- `skyclaw-automation`: Heartbeat & cron
- `skyclaw-observable`: Logging, metrics, tracing
- `skyclaw-filestore`: File storage backends
- `skyclaw` (binary): CLI entry point

## Consequences
- Clear separation of concerns — each crate has a focused responsibility
- Feature flags can exclude entire crates (e.g., `--no-default-features` to skip browser)
- Parallel compilation of independent crates speeds up builds
- More complex Cargo.toml management
- All crates depend on `skyclaw-core` for trait definitions
