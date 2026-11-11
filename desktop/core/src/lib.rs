mod auth;
mod claude;
mod codex_profile;
mod config;
mod credentials;
mod discovery;
mod history;
mod locations;
mod migration;
mod prices;
mod process;
mod runtime;
mod session;

pub use auth::LoginStatus;
pub use claude::{CLAUDE_ROUTE_ID, ClaudeSettings};
pub use config::{
    Algorithm, ConfigurationPreview, JevConfiguration, ModelTarget, RoleGroup, RouteSettings,
    RoutingRole, built_in_roles,
};
pub use credentials::CredentialVault;
pub use discovery::{AvailableModel, discover_models};
pub use locations::UserDataLocations;
pub use prices::{ModelPriceReader, ModelPrices, parse_price_map};
pub use runtime::{RuntimeLayout, RuntimeStatus};
pub use session::{DesktopSession, SessionStatus};

pub type Result<T> = std::result::Result<T, String>;
