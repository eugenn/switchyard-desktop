use std::{
    net::TcpListener,
    process::Command,
    time::{Duration, Instant},
};

use serde::Serialize;
use serde_json::Value;

use crate::{
    Algorithm, ClaudeSettings, CredentialVault, LoginStatus, Result, RouteSettings, RuntimeLayout,
    UserDataLocations,
    auth::LoginAttempt,
    claude::CLAUDE_KEY_ENV,
    codex_profile::CodexProfile,
    process::{OwnedProcess, python_command},
};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionStatus {
    pub running: bool,
    pub endpoint: String,
    pub message: String,
}

pub struct DesktopSession {
    locations: UserDataLocations,
    runtime: RuntimeLayout,
    client: reqwest::Client,
    login: Option<LoginAttempt>,
    server: Option<OwnedProcess>,
    litellm: Option<OwnedProcess>,
    message: String,
    codex_profile: Option<CodexProfile>,
    claude_route: bool,
    credentials: CredentialVault,
    router_port: u16,
    gateway_port: u16,
}

impl DesktopSession {
    pub fn new(locations: UserDataLocations, runtime: RuntimeLayout) -> Result<Self> {
        let client = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(2))
            .build()
            .map_err(|error| error.to_string())?;
        Ok(Self {
            locations,
            runtime,
            client,
            login: None,
            server: None,
            litellm: None,
            message: "Routing is stopped.".into(),
            codex_profile: None,
            claude_route: false,
            credentials: CredentialVault::current(),
            router_port: 4100,
            gateway_port: 4101,
        })
    }

    pub fn router_port(&self) -> u16 {
        self.router_port
    }

    pub fn set_typesafe_key(&self, key: &str) -> Result<()> {
        self.credentials.set_typesafe_key(key)
    }

    pub fn has_typesafe_key(&self) -> Result<bool> {
        self.credentials.has_typesafe_key()
    }

    pub fn set_anthropic_key(&self, key: &str) -> Result<()> {
        self.credentials.set_anthropic_key(key)
    }

    pub fn has_anthropic_key(&self) -> Result<bool> {
        self.credentials.has_anthropic_key()
    }

    pub fn begin_login(&mut self) -> Result<LoginStatus> {
        if self.status().running {
            return Err("Stop routing before signing in.".into());
        }
        if self.login.is_some() {
            return self.login_status();
        }
        if !self.runtime.status().available {
            return Err("Prepare the bundled runtime before signing in.".into());
        }
        std::fs::create_dir_all(self.locations.auth_directory())
            .map_err(|error| error.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(
                self.locations.auth_directory(),
                std::fs::Permissions::from_mode(0o700),
            )
            .map_err(|error| error.to_string())?;
        }
        let mut command = python_command(&self.runtime, &self.locations);
        command.arg("--login");
        self.login = Some(LoginAttempt::begin(&mut command)?);
        self.login_status()
    }

    pub fn login_status(&mut self) -> Result<LoginStatus> {
        let Some(login) = &mut self.login else {
            return Ok(LoginStatus {
                signed_in: self.has_auth_record(),
                message: "Sign in to the bundled LiteLLM ChatGPT provider.".into(),
                ..Default::default()
            });
        };
        let result = login.status();
        if !matches!(&result, Ok(status) if status.pending) {
            self.login.take();
        }
        result
    }

    fn has_auth_record(&self) -> bool {
        std::fs::read(self.locations.auth_directory().join("auth.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .is_some_and(|record| {
                ["access_token", "refresh_token"]
                    .iter()
                    .any(|key| record[*key].as_str().is_some_and(|value| !value.is_empty()))
            })
    }

    pub fn cancel_login(&mut self) -> LoginStatus {
        self.login.take();
        LoginStatus {
            message: "Sign-in cancelled.".into(),
            ..Default::default()
        }
    }

    pub fn status(&mut self) -> SessionStatus {
        let running = self
            .server
            .as_mut()
            .is_some_and(|process| process.is_running().unwrap_or(false))
            && self
                .litellm
                .as_mut()
                .is_none_or(|process| process.is_running().unwrap_or(false));
        if !running && (self.server.is_some() || self.litellm.is_some()) {
            self.stop();
            self.message = "A bundled service exited. Routing stopped; review the runtime and sign-in state before retrying.".into();
        }
        SessionStatus {
            running,
            endpoint: format!("http://127.0.0.1:{}/v1", self.router_port),
            message: self.message.clone(),
        }
    }

    pub async fn start(&mut self, settings: &RouteSettings) -> Result<SessionStatus> {
        if self.status().running {
            return Err("Stop the current route before applying another configuration.".into());
        }
        let outcome = self.start_inner(settings).await;
        if let Err(error) = outcome {
            self.stop();
            self.message = error.clone();
            return Err(error);
        }
        let codex = if self.codex_profile.is_some() {
            "Routing is running. Launch Codex with: codex --profile switch. Your config.toml is unchanged."
        } else {
            "Routing is running. Codex configuration is unchanged."
        };
        self.message = if self.claude_route {
            format!(
                "{codex} The Claude Code route is on: start Claude Code with the command in Claude setup."
            )
        } else {
            codex.into()
        };
        Ok(self.status())
    }

    async fn start_inner(&mut self, settings: &RouteSettings) -> Result<()> {
        let preview = settings.preview()?;
        let key = if settings.jev_classifier.is_some() {
            Some(self.credentials.typesafe_key()?.ok_or(
                "Save the TypeSafe API key in the system credential vault before starting Jev.",
            )?)
        } else {
            None
        };
        // The Claude Code route is optional. When both Claude models are saved it is
        // served by this same server, authenticated upstream with the Anthropic key.
        let claude = ClaudeSettings::load(&self.locations)?;
        let claude_key = if claude.enabled() {
            Some(self.credentials.anthropic_key()?.ok_or(
                "Save the Anthropic API key in the system credential vault before starting Claude Code routing.",
            )?)
        } else {
            None
        };
        let switchyard = if claude.enabled() {
            let mut document: toml::Table = preview
                .switchyard
                .parse()
                .map_err(|_| "The generated configuration could not be read back.")?;
            claude.extend_document(&mut document)?;
            toml::to_string_pretty(&document).map_err(|error| error.to_string())?
        } else {
            preview.switchyard.clone()
        };
        let runtime = self.runtime.status();
        if !runtime.available {
            return Err(format!(
                "Bundled runtime is not ready: {}. Run npm run runtime in desktop/.",
                runtime.missing.join(", ")
            ));
        }
        if self.login.is_some() {
            return Err("Finish or cancel sign-in before starting routing.".into());
        }
        let needs_gateway = settings.algorithm != Algorithm::Noop;
        if needs_gateway && !self.has_auth_record() {
            return Err("Sign in with ChatGPT before starting routing.".into());
        }
        let router_reservation = reserve_port(self.router_port)?;
        let litellm_reservation = if needs_gateway {
            Some(reserve_port(self.gateway_port)?)
        } else {
            None
        };
        self.locations.write("routes.toml", &switchyard)?;
        self.locations.write("litellm.json", &preview.litellm)?;
        if needs_gateway {
            let mut check = python_command(&self.runtime, &self.locations);
            check.arg("--check");
            OwnedProcess::spawn(&mut check)?
                .wait_success(Duration::from_secs(30))
                .await
                .map_err(|error| {
                    format!("LiteLLM 1.97.0 / FastAPI 0.136.3 validation failed: {error}")
                })?;
        }
        let mut validation = Command::new(self.runtime.server());
        validation
            .arg("--config")
            .arg(self.locations.root().join("routes.toml"))
            .arg("--dry-run");
        if let Some(key) = &key {
            validation.env("TYPESAFE_API_KEY", key);
        }
        if let Some(key) = &claude_key {
            validation.env(CLAUDE_KEY_ENV, key);
        }
        OwnedProcess::spawn(&mut validation)?
            .wait_success(Duration::from_secs(15))
            .await
            .map_err(|error| format!("Switchyard rejected the generated configuration: {error}"))?;
        drop(litellm_reservation);
        let litellm = if needs_gateway {
            let mut proxy = python_command(&self.runtime, &self.locations);
            proxy
                .arg("--config")
                .arg(self.locations.root().join("litellm.json"))
                .args(["--host", "127.0.0.1", "--port"])
                .arg(self.gateway_port.to_string());
            let mut litellm = OwnedProcess::spawn(&mut proxy)?;
            self.wait_ready(
                &mut litellm,
                &format!("http://127.0.0.1:{}/health/liveliness", self.gateway_port),
            )
            .await?;
            Some(litellm)
        } else {
            None
        };
        drop(router_reservation);
        let mut command = Command::new(self.runtime.server());
        command
            .arg("--config")
            .arg(self.locations.root().join("routes.toml"))
            .args(["--host", "127.0.0.1", "--port"])
            .arg(self.router_port.to_string())
            .arg("--routing-log-file")
            .arg(self.locations.root().join("routing-log.jsonl"));
        if let Some(key) = &key {
            command.env("TYPESAFE_API_KEY", key);
        }
        if let Some(key) = &claude_key {
            command.env(CLAUDE_KEY_ENV, key);
        }
        let mut server = OwnedProcess::spawn(&mut command)?;
        self.wait_ready(
            &mut server,
            &format!("http://127.0.0.1:{}/v1/models", self.router_port),
        )
        .await?;
        // Every start selects the route for `codex --profile switch`.
        let profile = Some(CodexProfile::install(&self.locations, &preview.codex)?);
        self.locations.save_settings(settings)?;
        self.codex_profile = profile;
        self.claude_route = claude.enabled();
        self.litellm = litellm;
        self.server = Some(server);
        Ok(())
    }

    async fn wait_ready(&self, process: &mut OwnedProcess, endpoint: &str) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(35);
        loop {
            if !process.is_running()? {
                return Err("Bundled service exited during startup. Check runtime dependencies and LiteLLM authentication.".into());
            }
            if let Ok(response) = self.client.get(endpoint).send().await {
                if response.status().is_success() {
                    return Ok(());
                }
            }
            if Instant::now() >= deadline {
                return Err("Bundled service did not become ready within 35 seconds.".into());
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    }

    pub async fn stats(&mut self) -> Result<Value> {
        if !self.status().running {
            return Err("Start routing to read live statistics.".into());
        }
        let mut response = self
            .client
            .get(format!("http://127.0.0.1:{}/v1/stats", self.router_port))
            .send()
            .await
            .map_err(|_| "Could not reach the managed Switchyard server.".to_string())?
            .error_for_status()
            .map_err(|error| format!("Statistics request failed: {}", error.status().unwrap()))?;
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "Could not read statistics.".to_string())?
        {
            if bytes.len() + chunk.len() > 4 * 1024 * 1024 {
                return Err("Statistics response exceeds 4 MiB.".into());
            }
            bytes.extend_from_slice(&chunk);
        }
        serde_json::from_slice(&bytes).map_err(|_| "Switchyard returned invalid statistics.".into())
    }

    pub fn stop(&mut self) -> SessionStatus {
        self.login.take();
        self.server.take();
        self.litellm.take();
        self.claude_route = false;
        self.message = match self.codex_profile.take().map(|mut profile| profile.remove()) {
            Some(Err(error)) => format!("Routing is stopped. {error}"),
            Some(Ok(())) => "Routing is stopped. The generated Codex profile was removed; config.toml is unchanged.".into(),
            None => "Routing is stopped. Your Codex configuration is unchanged.".into(),
        };
        SessionStatus {
            running: false,
            endpoint: format!("http://127.0.0.1:{}/v1", self.router_port),
            message: self.message.clone(),
        }
    }
}

fn reserve_port(port: u16) -> Result<TcpListener> {
    if let Ok(listener) = TcpListener::bind(("127.0.0.1", port)) {
        return Ok(listener);
    }
    free_port(port);
    TcpListener::bind(("127.0.0.1", port)).map_err(|_| {
        format!("Port {port} is in use and could not be freed. Stop the other application first.")
    })
}

/// Terminates other processes listening on `port` (never this process): SIGTERM first, SIGKILL if still bound.
fn free_port(port: u16) {
    let own = std::process::id();
    for signal in ["-TERM", "-KILL"] {
        let pids = listening_pids(port);
        let others: Vec<u32> = pids.into_iter().filter(|pid| *pid != own).collect();
        if others.is_empty() {
            return;
        }
        for pid in others {
            let _ = std::process::Command::new("/bin/kill")
                .args([signal, &pid.to_string()])
                .status();
        }
        for _ in 0..20 {
            std::thread::sleep(std::time::Duration::from_millis(100));
            if TcpListener::bind(("127.0.0.1", port)).is_ok() {
                return;
            }
        }
    }
}

fn listening_pids(port: u16) -> Vec<u32> {
    std::process::Command::new("/usr/sbin/lsof")
        .args(["-nP", "-t", &format!("-iTCP:{port}"), "-sTCP:LISTEN"])
        .output()
        .map(|out| {
            String::from_utf8_lossy(&out.stdout)
                .lines()
                .filter_map(|line| line.trim().parse().ok())
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn occupied_ports_are_not_reclaimed() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        assert!(reserve_port(listener.local_addr().unwrap().port()).is_err());
        assert!(listener.local_addr().is_ok());
    }

    #[test]
    fn a_device_challenge_record_is_not_a_signed_in_account() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().to_path_buf());
        std::fs::create_dir(locations.auth_directory()).unwrap();
        std::fs::write(
            locations.auth_directory().join("auth.json"),
            r#"{"device_code_requested_at":123}"#,
        )
        .unwrap();
        let mut session = DesktopSession::new(
            locations,
            RuntimeLayout::bundled(directory.path().join("runtime")),
        )
        .unwrap();
        assert!(!session.login_status().unwrap().signed_in);
        assert!(!session.stop().running);
    }

    #[tokio::test]
    async fn invalid_start_does_not_create_user_files() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("user-data");
        let mut session = DesktopSession::new(
            UserDataLocations::injected(root.clone()),
            RuntimeLayout::bundled(directory.path().join("runtime")),
        )
        .unwrap();
        assert!(session.start(&RouteSettings::default()).await.is_err());
        assert!(!root.exists());
        assert!(!session.status().running);
        assert!(session.stats().await.is_err());
    }
    fn claude_models() -> ClaudeSettings {
        ClaudeSettings {
            efficient_model: "claude-sonnet-test".into(),
            capable_model: "claude-opus-test".into(),
        }
    }

    #[tokio::test]
    async fn claude_route_refuses_to_start_without_the_anthropic_key_and_writes_nothing() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().join("app"));
        claude_models().save(&locations).unwrap();
        let before = std::fs::read_dir(locations.root()).unwrap().count();
        let mut session = DesktopSession::new(
            locations.clone(),
            RuntimeLayout::bundled(directory.path().join("missing-runtime")),
        )
        .unwrap();
        assert!(!session.has_anthropic_key().unwrap());
        let settings = RouteSettings {
            algorithm: Algorithm::Noop,
            ..Default::default()
        };
        let error = session.start(&settings).await.unwrap_err();
        assert!(error.contains("Anthropic API key"), "{error}");
        assert!(!session.status().running);
        assert!(!locations.root().join("routes.toml").exists());
        assert_eq!(std::fs::read_dir(locations.root()).unwrap().count(), before);
        // A configured Claude route never changes the Codex-only path.
        ClaudeSettings::default().save(&locations).unwrap();
        let error = session.start(&settings).await.unwrap_err();
        assert!(error.contains("Bundled runtime is not ready"), "{error}");
    }

    #[tokio::test]
    #[ignore = "requires a prepared bundled runtime; uses ephemeral ports and no account or network"]
    async fn claude_route_is_served_beside_codex_and_the_key_never_reaches_a_file() {
        const SECRET: &str = "sk-ant-test-not-a-real-key";
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().join("app"));
        claude_models().save(&locations).unwrap();
        let runtime = RuntimeLayout::bundled(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../src-tauri/runtime"),
        );
        let mut session = DesktopSession::new(locations.clone(), runtime).unwrap();
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        session.router_port = listener.local_addr().unwrap().port();
        drop(listener);
        session.set_anthropic_key(SECRET).unwrap();
        let settings = RouteSettings {
            algorithm: Algorithm::Noop,
            ..Default::default()
        };
        assert!(session.start(&settings).await.unwrap().running);
        assert!(session.status().message.contains("Claude Code route is on"));
        let models: Value = session
            .client
            .get(format!(
                "http://127.0.0.1:{}/v1/models",
                session.router_port
            ))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let served: Vec<&str> = models["data"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|model| model["id"].as_str())
            .collect();
        assert!(served.contains(&crate::CLAUDE_ROUTE_ID), "{served:?}");
        assert!(served.contains(&"switchyard-desktop"), "{served:?}");
        let routes = std::fs::read_to_string(locations.root().join("routes.toml")).unwrap();
        assert!(routes.contains("api_key_env = \"ANTHROPIC_API_KEY\""));
        for entry in std::fs::read_dir(locations.root()).unwrap() {
            let path = entry.unwrap().path();
            if path.is_file() {
                assert!(
                    !std::fs::read_to_string(&path)
                        .unwrap_or_default()
                        .contains(SECRET),
                    "{path:?} contains the key"
                );
            }
        }
        assert!(!session.stop().running);
        assert!(!session.status().message.contains("Claude Code route"));
    }

    #[tokio::test]
    #[ignore = "requires a prepared bundled runtime; uses ephemeral ports and no account"]
    async fn noop_session_profile_and_rollback_use_only_injected_paths() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().join("app"));
        std::fs::create_dir_all(locations.codex_home()).unwrap();
        let user = locations.codex_home().join("config.toml");
        let profile = locations.codex_home().join("switch.config.toml");
        std::fs::write(&user, "# unchanged user config\n").unwrap();
        std::fs::write(&profile, "foreign profile").unwrap();
        let runtime = RuntimeLayout::bundled(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../src-tauri/runtime"),
        );
        let mut session = DesktopSession::new(locations.clone(), runtime).unwrap();
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        session.router_port = listener.local_addr().unwrap().port();
        drop(listener);
        let settings = RouteSettings {
            algorithm: Algorithm::Noop,
            ..Default::default()
        };
        let error = session.start(&settings).await.unwrap_err();
        assert!(
            error.contains("Existing files are never replaced"),
            "{error}"
        );
        assert!(!session.status().running);
        assert!(
            session
                .client
                .get(format!(
                    "http://127.0.0.1:{}/v1/models",
                    session.router_port
                ))
                .send()
                .await
                .is_err()
        );
        assert_eq!(
            std::fs::read_to_string(&profile).unwrap(),
            "foreign profile"
        );
        assert!(!locations.root().join("settings.json").exists());
        std::fs::remove_file(&profile).unwrap();
        assert!(session.start(&settings).await.unwrap().running);
        assert!(session.litellm.is_none());
        assert!(profile.exists());
        assert!(!locations.auth_directory().exists());
        assert!(session.stats().await.is_ok());
        assert!(!session.stop().running);
        assert!(!profile.exists());
        assert_eq!(
            std::fs::read_to_string(&user).unwrap(),
            "# unchanged user config\n"
        );
        assert!(session.start(&settings).await.unwrap().running);
        std::fs::write(&profile, "edited while routing").unwrap();
        assert!(session.stop().message.contains("preserved"));
        assert_eq!(
            std::fs::read_to_string(&profile).unwrap(),
            "edited while routing"
        );
    }
}
