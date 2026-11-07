use std::{
    io::Write,
    path::{Path, PathBuf},
};

use crate::{Result, RoleGroup, RouteSettings, RoutingRole};

#[derive(Clone, Debug)]
pub struct UserDataLocations {
    root: PathBuf,
    codex_home: PathBuf,
    claude_home: PathBuf,
    user_home: PathBuf,
}

impl UserDataLocations {
    pub fn injected(root: PathBuf) -> Self {
        let codex_home = root.join("codex");
        let claude_home = root.join("claude");
        let user_home = root.join("home");
        Self {
            root,
            codex_home,
            claude_home,
            user_home,
        }
    }

    fn test_locations() -> Self {
        Self::injected(
            std::env::temp_dir()
                .join(format!("SwitchyardDesktopTests-{}", std::process::id()))
                .join("cross-platform"),
        )
    }

    pub fn current() -> Result<Self> {
        let test_executable = std::env::current_exe().ok().is_some_and(|path| {
            path.parent().and_then(Path::file_name) == Some(std::ffi::OsStr::new("deps"))
        });
        if cfg!(test) || test_executable {
            return Ok(Self::test_locations());
        }
        #[cfg(target_os = "macos")]
        let root = PathBuf::from(std::env::var_os("HOME").ok_or("HOME is unavailable")?)
            .join("Library/Application Support");
        #[cfg(target_os = "windows")]
        let root =
            PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or("LOCALAPPDATA is unavailable")?);
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        return Err("This prototype supports macOS and Windows only.".into());
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        {
            let mut locations =
                Self::injected(root.join("switchyard-desktop").join("cross-platform"));
            let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
                .map(PathBuf::from)
                .ok_or("User home is unavailable")?;
            locations.codex_home = std::env::var_os("CODEX_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".codex"));
            locations.claude_home = std::env::var_os("CLAUDE_CONFIG_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".claude"));
            locations.user_home = home;
            Ok(locations)
        }
    }

    pub fn codex_home(&self) -> &Path {
        &self.codex_home
    }

    pub fn claude_home(&self) -> &Path {
        &self.claude_home
    }

    pub fn user_home(&self) -> &Path {
        &self.user_home
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn auth_directory(&self) -> PathBuf {
        self.root.join("chatgpt")
    }

    pub fn read_settings(&self) -> Result<RouteSettings> {
        match std::fs::read(self.root.join("settings.json")) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|error| format!("Could not read saved routing settings: {error}")),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Ok(RouteSettings::default())
            }
            Err(error) => Err(format!("Could not read saved routing settings: {error}")),
        }
    }

    pub fn save_role_library(&self, roles: Vec<RoutingRole>, groups: Vec<RoleGroup>) -> Result<()> {
        let mut settings = self.read_settings()?;
        settings.roles = roles;
        settings.role_groups = groups;
        settings.validate_library()?;
        self.write(
            "settings.json",
            &serde_json::to_string_pretty(&settings).map_err(|error| error.to_string())?,
        )
    }

    pub fn save_settings(&self, settings: &RouteSettings) -> Result<()> {
        settings.validate()?;
        self.write(
            "settings.json",
            &serde_json::to_string_pretty(settings).map_err(|error| error.to_string())?,
        )
    }

    pub(crate) fn write(&self, filename: &str, content: &str) -> Result<()> {
        std::fs::create_dir_all(&self.root).map_err(|error| error.to_string())?;
        let mut file =
            tempfile::NamedTempFile::new_in(&self.root).map_err(|error| error.to_string())?;
        file.write_all(content.as_bytes())
            .map_err(|error| error.to_string())?;
        file.as_file()
            .sync_all()
            .map_err(|error| error.to_string())?;
        file.persist(self.root.join(filename))
            .map_err(|error| error.to_string())?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Algorithm;

    #[test]
    fn default_locations_never_resolve_the_real_user_home_in_tests() {
        let locations = UserDataLocations::current().unwrap();
        assert!(locations.root().starts_with(std::env::temp_dir()));
        assert_eq!(locations.codex_home(), locations.root().join("codex"));
        assert_eq!(locations.claude_home(), locations.root().join("claude"));
        assert_eq!(locations.user_home(), locations.root().join("home"));
        assert!(
            locations
                .root()
                .to_string_lossy()
                .contains(&format!("SwitchyardDesktopTests-{}", std::process::id()))
        );
    }

    #[test]
    fn saves_and_replaces_only_injected_app_files() {
        let temporary = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(temporary.path().join("app"));
        let mut settings = RouteSettings {
            algorithm: Algorithm::Passthrough,
            efficient_model: "first".into(),
            capable_model: String::new(),
            ..Default::default()
        };
        locations.save_settings(&settings).unwrap();
        settings.efficient_model = "second".into();
        locations.save_settings(&settings).unwrap();
        assert_eq!(locations.read_settings().unwrap(), settings);
        assert!(!temporary.path().join(".codex").exists());
    }

    #[test]
    fn invalid_settings_and_corrupted_files_are_not_overwritten() {
        let temporary = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(temporary.path().to_path_buf());
        locations.write("settings.json", "broken").unwrap();
        assert!(locations.read_settings().is_err());
        assert!(locations.save_settings(&RouteSettings::default()).is_err());
        assert_eq!(
            std::fs::read_to_string(temporary.path().join("settings.json")).unwrap(),
            "broken"
        );
    }
    #[test]
    fn role_library_persists_without_a_valid_route_and_preserves_route_drafts() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().into());
        let mut roles = crate::built_in_roles();
        roles[1].name = "My persisted role".into();
        roles[1].system_prompt = Some("Inspect before changing code.".into());
        roles[1].group_ids = vec!["project".into()];
        let groups = vec![RoleGroup {
            id: "project".into(),
            name: "Project roles".into(),
            project_path: "/label-only".into(),
            routing_profile: None,
        }];
        locations
            .save_role_library(roles.clone(), groups.clone())
            .unwrap();
        let restored = locations.read_settings().unwrap();
        assert!(restored.efficient_model.is_empty());
        assert_eq!(restored.roles, roles);
        assert_eq!(restored.role_groups, groups);
        assert!(restored.validate().is_err());
        let bytes = std::fs::read(directory.path().join("settings.json")).unwrap();
        roles[1].group_ids = vec!["missing".into()];
        assert!(locations.save_role_library(roles, vec![]).is_err());
        assert_eq!(
            std::fs::read(directory.path().join("settings.json")).unwrap(),
            bytes
        );
    }
    #[test]
    fn persisted_group_setups_roundtrip_without_nested_group_profiles() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().into());
        let profile = RouteSettings {
            algorithm: Algorithm::Noop,
            ..Default::default()
        };
        let settings = RouteSettings {
            algorithm: Algorithm::Noop,
            role_groups: vec![RoleGroup {
                id: "project".into(),
                name: "Project".into(),
                project_path: "C:/label".into(),
                routing_profile: Some(Box::new(profile)),
            }],
            ..Default::default()
        };
        locations.save_settings(&settings).unwrap();
        assert_eq!(locations.read_settings().unwrap(), settings);
        let mut nested = settings.clone();
        nested.role_groups[0].routing_profile = Some(Box::new(settings));
        assert!(
            locations
                .save_settings(&nested)
                .unwrap_err()
                .contains("nested")
        );
    }
}
