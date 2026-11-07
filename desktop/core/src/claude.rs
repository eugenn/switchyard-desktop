use std::{
    path::PathBuf,
    process::Command,
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};

use crate::{Result, RuntimeLayout, UserDataLocations, process::OwnedProcess};

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct ClaudeSettings {
    pub executable: String,
    pub efficient_model: String,
    pub capable_model: String,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeStatus {
    pub installed: bool,
    pub version: String,
    pub signed_in: bool,
    pub subscription_auth: bool,
    pub pending: bool,
    pub supported: bool,
    pub plugin_available: bool,
    pub message: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedClaudePlugin {
    pub directory: PathBuf,
    pub command: String,
}

pub struct ClaudeIntegration {
    locations: UserDataLocations,
    runtime: RuntimeLayout,
    login: Option<(OwnedProcess, Instant)>,
}

impl ClaudeSettings {
    fn validate(&self) -> Result<()> {
        if self.executable.len() > 4096 || self.executable.chars().any(char::is_control) {
            return Err("Invalid Claude Code executable path.".into());
        }
        if !self.executable.is_empty() && !std::path::Path::new(&self.executable).is_absolute() {
            return Err(
                "Use an absolute Claude Code executable path, or leave it empty for PATH.".into(),
            );
        }
        Ok(())
    }

    fn configuration(&self) -> Result<String> {
        self.validate()?;
        for model in [&self.efficient_model, &self.capable_model] {
            if !model.starts_with("claude-")
                || model.len() <= 7
                || model.len() > 200
                || !model
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
            {
                return Err("Enter exact native Claude model IDs (claude-...) for both tiers. Availability is checked by Claude Code, not inferred from your subscription.".into());
            }
        }
        let mut config: toml::Table =
            include_str!("../../../vendor/switchyard/examples/claude/switchyard.toml")
                .parse()
                .map_err(|_| "Invalid bundled Claude routing template.")?;
        config["targets"]["efficient"]["id"] = self.efficient_model.clone().into();
        config["targets"]["capable"]["id"] = self.capable_model.clone().into();
        toml::to_string_pretty(&config).map_err(|error| error.to_string())
    }
}

impl ClaudeIntegration {
    pub fn new(locations: UserDataLocations, runtime: RuntimeLayout) -> Self {
        Self {
            locations,
            runtime,
            login: None,
        }
    }

    pub fn settings(&self) -> Result<ClaudeSettings> {
        match std::fs::read(self.locations.root().join("claude-settings.json")) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|_| "Could not read Claude integration settings.".into()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Ok(ClaudeSettings::default())
            }
            Err(_) => Err("Could not read Claude integration settings.".into()),
        }
    }

    fn command(&self, settings: &ClaudeSettings) -> Result<Command> {
        settings.validate()?;
        let mut command = Command::new(if settings.executable.is_empty() {
            "claude"
        } else {
            &settings.executable
        });
        command
            .env("CLAUDE_CONFIG_DIR", self.locations.claude_home())
            .env("HOME", self.locations.user_home())
            .env("USERPROFILE", self.locations.user_home())
            .current_dir(self.locations.root());
        Ok(command)
    }

    pub fn begin_login(&mut self, settings: &ClaudeSettings) -> Result<ClaudeStatus> {
        if self.login.is_some() {
            return Err("A Claude Code sign-in is already pending.".into());
        }
        settings.validate()?;
        std::fs::create_dir_all(self.locations.root()).map_err(|error| error.to_string())?;
        self.locations.write(
            "claude-settings.json",
            &serde_json::to_string(settings).map_err(|error| error.to_string())?,
        )?;
        let mut command = self.command(settings)?;
        command.args(["auth", "login"]);
        let process = OwnedProcess::spawn(&mut command)?;
        self.login = Some((process, Instant::now()));
        Ok(ClaudeStatus { pending: true, message: "Complete sign-in in the browser opened by Claude Code. Switchyard never reads or stores the subscription token.".into(), ..self.base_status() })
    }

    fn base_status(&self) -> ClaudeStatus {
        let directory = self.runtime.root().join("claude-plugin");
        let snapshot_matches = std::fs::read(self.runtime.root().join("switchyard-source.json"))
            .is_ok_and(|bytes| bytes == include_bytes!("../../../vendor/switchyard-source.json"));
        ClaudeStatus {
            supported: cfg!(target_os = "macos"),
            plugin_available: cfg!(target_os = "macos")
                && snapshot_matches
                && [
                    "bin/switchyard-claude",
                    "hooks/register.mjs",
                    "hooks/hooks.json",
                    ".claude-plugin/plugin.json",
                    "LICENSE",
                    "NOTICE",
                ]
                .iter()
                .all(|path| directory.join(path).is_file()),
            ..Default::default()
        }
    }

    pub fn cancel_login(&mut self) -> ClaudeStatus {
        self.login.take();
        ClaudeStatus {
            message: "Claude Code sign-in cancelled. Existing Claude credentials were not removed."
                .into(),
            ..self.base_status()
        }
    }

    async fn output(
        &self,
        settings: &ClaudeSettings,
        arguments: &[&str],
    ) -> Result<(bool, Vec<u8>)> {
        std::fs::create_dir_all(self.locations.root()).map_err(|error| error.to_string())?;
        let mut command = self.command(settings)?;
        command.args(arguments);
        let (mut process, output) = OwnedProcess::capture_limited(&mut command, 65537)?;
        let deadline = Instant::now() + Duration::from_secs(15);
        let success = loop {
            if let Some(success) = process.exit_success()? {
                break success;
            }
            if Instant::now() >= deadline {
                return Err("Claude Code did not respond within 15 seconds.".into());
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        };
        process.finish_output().await?;
        let bytes = output
            .lock()
            .map_err(|_| "Could not read Claude Code status.")?
            .clone();
        if bytes.len() > 65536 {
            return Err("Claude Code status exceeded the output limit.".into());
        }
        Ok((success, bytes))
    }

    pub async fn status(&mut self, settings: &ClaudeSettings) -> Result<ClaudeStatus> {
        settings.validate()?;
        let mut status = self.base_status();
        if let Some((process, started)) = &mut self.login {
            if started.elapsed() > Duration::from_secs(15 * 60) {
                self.login.take();
                return Err(
                    "Claude Code sign-in timed out. Retry when ready to finish in your browser."
                        .into(),
                );
            }
            match process.exit_success()? {
                None => {
                    return Ok(ClaudeStatus {
                        pending: true,
                        message: "Waiting for Claude Code browser sign-in.".into(),
                        ..status
                    });
                }
                Some(false) => {
                    self.login.take();
                    return Err("Claude Code sign-in did not finish. Retry, or run claude auth login in your terminal and check the account again.".into());
                }
                Some(true) => {
                    self.login.take();
                }
            }
        }
        let (success, bytes) = self.output(settings, &["--version"]).await?;
        if !success {
            return Err("Claude Code version check failed.".into());
        }
        let version =
            String::from_utf8(bytes).map_err(|_| "Invalid Claude Code version output.")?;
        status.version = version.trim().chars().take(120).collect();
        status.installed = true;
        let (success, bytes) = self.output(settings, &["auth", "status"]).await?;
        let auth: serde_json::Value = serde_json::from_slice(&bytes).map_err(
            |_| "Claude Code returned an unsupported account status. Update Claude Code and retry.",
        )?;
        status.signed_in = success && auth["loggedIn"] == true;
        status.subscription_auth = status.signed_in && auth["authMethod"] == "claude.ai";
        status.message = if !status.signed_in {
            "Claude Code is not signed in. Sign in with your Claude subscription."
        } else if !status.subscription_auth {
            "Claude Code is authenticated, but not with a Claude subscription login. Check claude auth status in your terminal; Switchyard does not change authentication overrides."
        } else {
            "Claude subscription connected through the original Claude Code CLI. Credentials stay with Claude Code."
        }.into();
        if !status.supported {
            status.message.push_str(" Native Switchyard plugin packaging is currently macOS-only; Windows requires a core helper port.");
        } else if !compatible_version(&status.version) {
            status.plugin_available = false;
            status
                .message
                .push_str(" Routing requires Claude Code 2.1.301 or newer with mods enabled.");
        } else if !status.plugin_available {
            status.message.push_str(" Prepare the matching bundled plugin with python3 scripts/prepare-runtime.py --claude-plugin in desktop/.");
        }
        Ok(status)
    }

    pub async fn prepare(&mut self, settings: &ClaudeSettings) -> Result<PreparedClaudePlugin> {
        let config = settings.configuration()?;
        let status = self.status(settings).await?;
        if !status.supported || !status.plugin_available {
            return Err("The native Claude plugin is unavailable. On macOS prepare the bundled runtime with --claude-plugin; use Claude Code 2.1.301+ with mods enabled. Windows is not supported yet.".into());
        }
        if status.pending || !status.subscription_auth {
            return Err("Complete a Claude subscription login in the original Claude Code CLI before preparing routing.".into());
        }
        let parent = self.locations.root().join("claude-plugins");
        std::fs::create_dir_all(&parent).map_err(|error| error.to_string())?;
        let staged = tempfile::Builder::new()
            .prefix("switchyard-")
            .tempdir_in(&parent)
            .map_err(|error| error.to_string())?;
        let source = self.runtime.root().join("claude-plugin");
        for relative in [
            "bin/switchyard-claude",
            "hooks/register.mjs",
            "hooks/hooks.json",
            ".claude-plugin/plugin.json",
            "LICENSE",
            "NOTICE",
        ] {
            let destination = staged.path().join(relative);
            std::fs::create_dir_all(destination.parent().unwrap())
                .map_err(|error| error.to_string())?;
            std::fs::copy(source.join(relative), destination)
                .map_err(|error| format!("Could not stage the bundled Claude plugin: {error}"))?;
        }
        std::fs::write(staged.path().join("switchyard.toml"), config)
            .map_err(|error| error.to_string())?;
        self.locations.write(
            "claude-settings.json",
            &serde_json::to_string(settings).map_err(|error| error.to_string())?,
        )?;
        let directory = staged.keep();
        let command = format!(
            "CLAUDE_CONFIG_DIR={} SWITCHYARD_CONFIG={} {} --plugin-dir {}",
            shell_quote(self.locations.claude_home().to_string_lossy().as_ref()),
            shell_quote(directory.join("switchyard.toml").to_string_lossy().as_ref()),
            shell_quote(if settings.executable.is_empty() {
                "claude"
            } else {
                &settings.executable
            }),
            shell_quote(directory.to_string_lossy().as_ref())
        );
        Ok(PreparedClaudePlugin { directory, command })
    }
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn compatible_version(version: &str) -> bool {
    let parts = version
        .split_whitespace()
        .next()
        .unwrap_or("")
        .split('.')
        .map(str::parse::<u32>)
        .collect::<std::result::Result<Vec<_>, _>>();
    parts.is_ok_and(|parts| parts.len() == 3 && (parts[0], parts[1], parts[2]) >= (2, 1, 301))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_exact_model_ids_without_guessing_account_models() {
        let mut settings = ClaudeSettings {
            efficient_model: "claude-test-small".into(),
            capable_model: "claude-test-large".into(),
            ..Default::default()
        };
        let config: toml::Table = settings.configuration().unwrap().parse().unwrap();
        assert_eq!(
            config["targets"]["efficient"]["id"].as_str(),
            Some("claude-test-small")
        );
        assert_eq!(
            config["routes"]["claude"]["id"].as_str(),
            Some("switchyard")
        );
        assert_eq!(
            config["llm_clients"]["claude"]["format"].as_str(),
            Some("anthropic_messages")
        );
        assert!(!settings.configuration().unwrap().contains("api_key"));
        for invalid in [
            "",
            "sonnet",
            "gpt-test",
            "claude-",
            "claude-\"injection",
            "claude-bad\n",
        ] {
            settings.efficient_model = invalid.into();
            assert!(settings.configuration().is_err(), "accepted {invalid:?}");
        }
    }

    #[test]
    fn command_quotes_paths_and_enforces_minimum_version() {
        assert_eq!(shell_quote("/tmp/it's a path"), "'/tmp/it'\\''s a path'");
        assert!(!compatible_version("2.1.300 (Claude Code)"));
        assert!(compatible_version("2.1.301 (Claude Code)"));
        assert!(compatible_version("3.0.0 (Claude Code)"));
        assert!(!compatible_version("unrecognized"));
        assert!(
            ClaudeSettings {
                executable: "relative/claude".into(),
                ..Default::default()
            }
            .validate()
            .is_err()
        );
    }

    #[cfg(unix)]
    fn fixture() -> (tempfile::TempDir, ClaudeIntegration, ClaudeSettings) {
        use std::os::unix::fs::PermissionsExt;
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().join("app");
        std::fs::create_dir_all(&root).unwrap();
        let executable = temporary.path().join("claude mock's cli");
        std::fs::write(&executable, r##"#!/bin/sh
set -eu
printf '%s\n' "$HOME" "$USERPROFILE" "$CLAUDE_CONFIG_DIR" >> command-paths
if [ "$1" = "--version" ]; then echo '2.1.301 (Claude Code)'; exit 0; fi
if [ "$2" = "login" ]; then
  if [ -f wait-login ]; then exec /bin/sleep 60; fi
  printf '{"loggedIn":true,"authMethod":"claude.ai","accessToken":"mock-never-return-this"}' > status.json
  exit 0
fi
if [ -f status.json ]; then cat status.json; else echo '{"loggedIn":false,"authMethod":"none"}'; exit 1; fi
"##).unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let runtime = RuntimeLayout::bundled(temporary.path().join("runtime"));
        let integration = ClaudeIntegration::new(UserDataLocations::injected(root), runtime);
        let settings = ClaudeSettings {
            executable: executable.to_string_lossy().into(),
            efficient_model: "claude-test-small".into(),
            capable_model: "claude-test-large".into(),
        };
        (temporary, integration, settings)
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cli_owns_login_and_only_sanitized_status_reaches_the_ui() {
        let (_temporary, mut integration, settings) = fixture();
        assert!(!integration.status(&settings).await.unwrap().signed_in);
        assert!(integration.begin_login(&settings).unwrap().pending);
        assert!(integration.begin_login(&settings).is_err());
        let status = loop {
            let status = integration.status(&settings).await.unwrap();
            if !status.pending {
                break status;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        };
        assert!(status.signed_in && status.subscription_auth);
        assert!(
            !serde_json::to_string(&status)
                .unwrap()
                .contains("mock-never-return-this")
        );
        let saved =
            std::fs::read_to_string(integration.locations.root().join("claude-settings.json"))
                .unwrap();
        assert!(!saved.contains("accessToken"));
        let paths =
            std::fs::read_to_string(integration.locations.root().join("command-paths")).unwrap();
        assert!(
            paths
                .lines()
                .all(|path| PathBuf::from(path).starts_with(integration.locations.root()))
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn api_key_auth_and_bad_status_are_not_subscription_connections() {
        let (_temporary, mut integration, settings) = fixture();
        let path = integration.locations.root().join("status.json");
        std::fs::write(&path, r#"{"loggedIn":true,"authMethod":"api_key"}"#).unwrap();
        let status = integration.status(&settings).await.unwrap();
        assert!(status.signed_in);
        assert!(!status.subscription_auth);
        assert!(integration.prepare(&settings).await.is_err());
        std::fs::write(path, "not-json").unwrap();
        assert!(integration.status(&settings).await.is_err());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn login_timeout_stops_the_owned_process_without_returning_credentials() {
        let (_temporary, mut integration, settings) = fixture();
        std::fs::write(integration.locations.root().join("wait-login"), "").unwrap();
        integration.begin_login(&settings).unwrap();
        integration.login.as_mut().unwrap().1 = Instant::now() - Duration::from_secs(901);
        assert!(
            integration
                .status(&settings)
                .await
                .unwrap_err()
                .contains("timed out")
        );
        assert!(integration.login.is_none());
        assert!(!integration.locations.claude_home().exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cancelling_login_preserves_existing_credentials() {
        let (_temporary, mut integration, settings) = fixture();
        let status = integration.locations.root().join("status.json");
        std::fs::write(&status, r#"{"loggedIn":true,"authMethod":"claude.ai"}"#).unwrap();
        std::fs::write(integration.locations.root().join("wait-login"), "").unwrap();
        integration.begin_login(&settings).unwrap();
        integration.cancel_login();
        assert!(integration.login.is_none());
        assert!(
            integration
                .status(&settings)
                .await
                .unwrap()
                .subscription_auth
        );
        assert!(status.exists());
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn prepares_separate_plugins_only_from_the_matching_runtime() {
        let (_temporary, mut integration, settings) = fixture();
        std::fs::write(
            integration.locations.root().join("status.json"),
            r#"{"loggedIn":true,"authMethod":"claude.ai"}"#,
        )
        .unwrap();
        assert!(integration.prepare(&settings).await.is_err());
        let runtime = integration.runtime.root().clone();
        std::fs::create_dir_all(&runtime).unwrap();
        std::fs::write(
            runtime.join("switchyard-source.json"),
            include_bytes!("../../../vendor/switchyard-source.json"),
        )
        .unwrap();
        for relative in [
            "bin/switchyard-claude",
            "hooks/register.mjs",
            "hooks/hooks.json",
            ".claude-plugin/plugin.json",
            "LICENSE",
            "NOTICE",
        ] {
            let path = runtime.join("claude-plugin").join(relative);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, "bundled-fixture").unwrap();
        }
        let first = integration.prepare(&settings).await.unwrap();
        let second = integration.prepare(&settings).await.unwrap();
        assert_ne!(first.directory, second.directory);
        assert_eq!(
            std::fs::read_to_string(first.directory.join("hooks/register.mjs")).unwrap(),
            "bundled-fixture"
        );
        assert!(first.command.contains("--plugin-dir"));
        assert!(first.command.contains("'\\''"));
        assert!(!first.command.contains("api.anthropic.com"));
        assert!(!integration.locations.claude_home().exists());
        std::fs::write(runtime.join("switchyard-source.json"), "wrong-snapshot").unwrap();
        assert!(integration.prepare(&settings).await.is_err());
    }
}
