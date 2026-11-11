//! Claude Code routing through the app's own Switchyard server, authenticated with
//! the user's Anthropic API key.
//!
//! The key lives only in the system credential vault. The managed server receives
//! it in `ANTHROPIC_API_KEY` and makes every Anthropic call itself, including the
//! classifier. Claude Code is pointed at the local server and never sees the key.
//! No Claude subscription sign-in, plug-in or token is involved.

use serde::{Deserialize, Serialize};
use toml::{Table, Value};

use crate::{Result, UserDataLocations};

/// The model name Claude Code sends to select this route.
pub const CLAUDE_ROUTE_ID: &str = "switchyard-claude";
/// Environment variable the managed server reads the Anthropic key from.
pub(crate) const CLAUDE_KEY_ENV: &str = "ANTHROPIC_API_KEY";

const SETTINGS_FILE: &str = "claude-settings.json";
const TEMPLATE: &str = include_str!("../../../vendor/switchyard/examples/claude/switchyard.toml");

/// Saved Claude Code routing setup. Both models empty means the route is off.
/// Older saved files carried a Claude Code executable path; it is ignored.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(default, rename_all = "camelCase")]
pub struct ClaudeSettings {
    pub efficient_model: String,
    pub capable_model: String,
}

impl ClaudeSettings {
    pub fn load(locations: &UserDataLocations) -> Result<Self> {
        match std::fs::read(locations.root().join(SETTINGS_FILE)) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|_| "Could not read Claude Code routing settings.".into()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(_) => Err("Could not read Claude Code routing settings.".into()),
        }
    }

    pub fn save(&self, locations: &UserDataLocations) -> Result<()> {
        self.validate()?;
        locations.write(
            SETTINGS_FILE,
            &serde_json::to_string(self).map_err(|error| error.to_string())?,
        )
    }

    pub fn validate(&self) -> Result<()> {
        let models = [&self.efficient_model, &self.capable_model];
        if models.iter().all(|model| model.is_empty()) {
            return Ok(());
        }
        if models.iter().any(|model| model.is_empty()) {
            return Err(
                "Enter both Claude model IDs, or clear both to turn Claude Code routing off."
                    .into(),
            );
        }
        if models.iter().any(|model| !valid_model_id(model)) {
            return Err("Enter exact Claude model IDs (claude-...) for both tiers. The app does not guess which models your Anthropic account can use.".into());
        }
        Ok(())
    }

    /// Whether the managed server should serve the Claude Code route.
    pub fn enabled(&self) -> bool {
        !self.efficient_model.is_empty() && !self.capable_model.is_empty()
    }

    /// Adds the Claude Code route, its Anthropic client and its two targets to the
    /// generated server document. Does nothing while the route is off. The route
    /// reuses the shipped Composite policy and classifier prompt; unlike the retired
    /// native plug-in, the server now makes the classifier call with the API key.
    pub(crate) fn extend_document(&self, document: &mut Table) -> Result<()> {
        self.validate()?;
        if !self.enabled() {
            return Ok(());
        }
        let bundled = || "Invalid bundled Claude routing template.";
        let mut template: Table = TEMPLATE.parse().map_err(|_| bundled())?;
        let mut route = match template
            .get_mut("routes")
            .and_then(Value::as_table_mut)
            .and_then(|routes| routes.remove("claude"))
        {
            Some(Value::Table(route)) => route,
            _ => return Err(bundled().into()),
        };
        route.insert("id".into(), CLAUDE_ROUTE_ID.into());
        let classifier = route
            .get_mut("classifier")
            .and_then(Value::as_table_mut)
            .ok_or_else(bundled)?;
        classifier.insert("target".into(), "claude_efficient".into());
        let stage = route
            .get_mut("stage")
            .and_then(Value::as_table_mut)
            .ok_or_else(bundled)?;
        stage.insert("efficient_target".into(), "claude_efficient".into());
        stage.insert("capable_target".into(), "claude_capable".into());

        let mut client = Table::new();
        client.insert("format".into(), "anthropic_messages".into());
        client.insert("base_url".into(), "https://api.anthropic.com".into());
        client.insert("api_key_env".into(), CLAUDE_KEY_ENV.into());
        let mut targets = Table::new();
        for (key, model) in [
            ("claude_efficient", &self.efficient_model),
            ("claude_capable", &self.capable_model),
        ] {
            let mut target = Table::new();
            target.insert("id".into(), model.clone().into());
            target.insert("llm_client".into(), "claude".into());
            targets.insert(key.into(), target.into());
        }
        for (section, name, entry) in [
            ("llm_clients", "claude", Value::Table(client)),
            ("routes", "claude", Value::Table(route)),
        ] {
            let table = document
                .entry(section)
                .or_insert_with(|| Value::Table(Table::new()))
                .as_table_mut()
                .ok_or("Generated configuration has an unexpected shape.")?;
            if table.insert(name.into(), entry).is_some() {
                return Err("Generated configuration already defines a Claude entry.".into());
            }
        }
        let existing = document
            .entry("targets")
            .or_insert_with(|| Value::Table(Table::new()))
            .as_table_mut()
            .ok_or("Generated configuration has an unexpected shape.")?;
        for (key, target) in targets {
            if existing.insert(key, target).is_some() {
                return Err("Generated configuration already defines a Claude target.".into());
            }
        }
        Ok(())
    }

    /// The shell command that starts Claude Code against the local server. The
    /// token is a placeholder that only stops Claude Code from asking to sign in:
    /// the server ignores it and authenticates upstream with the stored API key.
    pub fn launch_command(&self, router_port: u16) -> Result<String> {
        self.validate()?;
        if !self.enabled() {
            return Err("Enter both Claude model IDs first.".into());
        }
        let variables = [
            (
                "ANTHROPIC_BASE_URL",
                format!("http://127.0.0.1:{router_port}"),
            ),
            ("ANTHROPIC_AUTH_TOKEN", "switchyard-local".into()),
            ("ANTHROPIC_MODEL", CLAUDE_ROUTE_ID.into()),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", CLAUDE_ROUTE_ID.into()),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", CLAUDE_ROUTE_ID.into()),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", CLAUDE_ROUTE_ID.into()),
            (
                "ANTHROPIC_CUSTOM_HEADERS",
                "x-switchyard-origin: claude-code".into(),
            ),
        ];
        let mut command = variables
            .iter()
            .map(|(name, value)| format!("{name}={}", shell_quote(value)))
            .collect::<Vec<_>>()
            .join(" ");
        command.push_str(" claude");
        Ok(command)
    }
}

fn valid_model_id(model: &str) -> bool {
    model.starts_with("claude-")
        && model.len() > 7
        && model.len() <= 200
        && model
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings() -> ClaudeSettings {
        ClaudeSettings {
            efficient_model: "claude-sonnet-test".into(),
            capable_model: "claude-opus-test".into(),
        }
    }

    fn document() -> Table {
        r#"
schema_version = 1
[llm_clients.openai]
format = "openai_responses"
base_url = "http://127.0.0.1:4101/v1"
[targets.efficient]
id = "gpt-test"
llm_client = "openai"
[routes.main]
id = "switchyard-desktop"
type = "auto"
"#
        .parse()
        .unwrap()
    }

    #[test]
    fn validates_exact_model_ids_without_guessing_account_models() {
        assert!(ClaudeSettings::default().validate().is_ok());
        assert!(!ClaudeSettings::default().enabled());
        assert!(settings().validate().is_ok());
        assert!(settings().enabled());
        for invalid in [
            "",
            "claude-",
            "sonnet",
            "gpt-5",
            "claude-opus 4",
            "claude-opus;rm",
            "claude-\u{e9}",
        ] {
            let mut candidate = settings();
            candidate.efficient_model = invalid.into();
            assert!(candidate.validate().is_err(), "accepted {invalid:?}");
        }
        let one_sided = ClaudeSettings {
            efficient_model: "claude-sonnet-test".into(),
            capable_model: String::new(),
        };
        assert!(one_sided.validate().is_err());
        assert!(!one_sided.enabled());
    }

    #[test]
    fn route_is_added_beside_the_codex_route_and_never_contains_a_secret() {
        let mut document = document();
        settings().extend_document(&mut document).unwrap();
        let text = toml::to_string_pretty(&document).unwrap();
        assert!(!text.to_lowercase().contains("sk-ant"));
        assert_eq!(
            document["routes"]["main"]["id"].as_str(),
            Some("switchyard-desktop")
        );
        let route = &document["routes"]["claude"];
        assert_eq!(route["id"].as_str(), Some(CLAUDE_ROUTE_ID));
        assert_eq!(route["type"].as_str(), Some("composite"));
        assert_eq!(
            route["classifier"]["target"].as_str(),
            Some("claude_efficient")
        );
        assert_eq!(
            route["stage"]["efficient_target"].as_str(),
            Some("claude_efficient")
        );
        assert_eq!(
            route["stage"]["capable_target"].as_str(),
            Some("claude_capable")
        );
        let client = &document["llm_clients"]["claude"];
        assert_eq!(client["format"].as_str(), Some("anthropic_messages"));
        assert_eq!(
            client["base_url"].as_str(),
            Some("https://api.anthropic.com")
        );
        assert_eq!(client["api_key_env"].as_str(), Some(CLAUDE_KEY_ENV));
        assert!(client.get("forward_auth").is_none());
        assert_eq!(
            document["targets"]["claude_efficient"]["id"].as_str(),
            Some("claude-sonnet-test")
        );
        assert_eq!(
            document["targets"]["claude_capable"]["id"].as_str(),
            Some("claude-opus-test")
        );
        assert_eq!(
            document["targets"]["claude_efficient"]["llm_client"].as_str(),
            Some("claude")
        );
        // The Codex route's own entries are untouched.
        assert_eq!(
            document["targets"]["efficient"]["id"].as_str(),
            Some("gpt-test")
        );
        assert_eq!(
            document["llm_clients"]["openai"]["format"].as_str(),
            Some("openai_responses")
        );
    }

    #[test]
    fn a_disabled_route_leaves_the_document_unchanged() {
        let mut document = document();
        let before = document.clone();
        ClaudeSettings::default()
            .extend_document(&mut document)
            .unwrap();
        assert_eq!(document, before);
    }

    #[test]
    fn extending_never_overwrites_an_existing_entry() {
        let mut document = document();
        settings().extend_document(&mut document).unwrap();
        assert!(settings().extend_document(&mut document).is_err());
    }

    #[test]
    fn launch_command_targets_the_local_server_and_carries_no_secret() {
        let command = settings().launch_command(4100).unwrap();
        assert!(command.contains("ANTHROPIC_BASE_URL='http://127.0.0.1:4100'"));
        assert!(command.contains("ANTHROPIC_MODEL='switchyard-claude'"));
        assert!(command.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='switchyard-claude'"));
        assert!(command.contains("x-switchyard-origin: claude-code"));
        assert!(command.ends_with(" claude"));
        assert!(!command.contains("ANTHROPIC_API_KEY"));
        assert!(ClaudeSettings::default().launch_command(4100).is_err());
    }

    #[test]
    fn settings_round_trip_through_injected_locations_and_ignore_legacy_fields() {
        let temporary = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(temporary.path().to_path_buf());
        assert_eq!(
            ClaudeSettings::load(&locations).unwrap(),
            ClaudeSettings::default()
        );
        settings().save(&locations).unwrap();
        assert_eq!(ClaudeSettings::load(&locations).unwrap(), settings());
        std::fs::write(
            temporary.path().join(SETTINGS_FILE),
            r#"{"executable":"/opt/claude","efficientModel":"claude-a","capableModel":"claude-b"}"#,
        )
        .unwrap();
        let legacy = ClaudeSettings::load(&locations).unwrap();
        assert_eq!(legacy.efficient_model, "claude-a");
        let invalid = ClaudeSettings {
            efficient_model: "nope".into(),
            capable_model: "claude-b".into(),
        };
        assert!(invalid.save(&locations).is_err());
    }
}
