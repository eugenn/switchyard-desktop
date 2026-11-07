use std::{io::Write, path::PathBuf};

use crate::{Result, UserDataLocations};

pub(crate) struct CodexProfile {
    path: PathBuf,
    contents: String,
}

impl CodexProfile {
    pub(crate) fn install(locations: &UserDataLocations, contents: &str) -> Result<Self> {
        let document: toml::Table =
            toml::from_str(contents).map_err(|error| format!("Invalid Codex profile: {error}"))?;
        if document.get("model_provider").and_then(toml::Value::as_str)
            != Some("switchyard-desktop")
        {
            return Err("The generated profile does not select Switchyard.".into());
        }
        let home = locations.codex_home();
        std::fs::create_dir_all(home)
            .map_err(|error| format!("Could not create Codex home: {error}"))?;
        let path = home.join("switch.config.toml");
        // Codex writes its own UI state into the profile file it was started with,
        // creating it when it is missing. That residue routes nothing, so it is
        // replaced; an existing Switchyard profile is also replaceable, but foreign files are kept.
        if is_codex_residue(&path) || is_stale_switchyard_profile(&path) {
            std::fs::remove_file(&path).map_err(|error| {
                format!("Could not replace Codex's leftover switch.config.toml: {error}")
            })?;
        }
        let mut temporary =
            tempfile::NamedTempFile::new_in(home).map_err(|error| error.to_string())?;
        temporary
            .write_all(contents.as_bytes())
            .map_err(|error| error.to_string())?;
        temporary
            .as_file()
            .sync_all()
            .map_err(|error| error.to_string())?;
        temporary.persist_noclobber(&path).map_err(|error| format!("Could not install switch.config.toml: {}. Existing files are never replaced; stop the other client or review the existing profile first.", error.error))?;
        Ok(Self {
            path,
            contents: contents.into(),
        })
    }

    pub(crate) fn remove(&mut self) -> Result<()> {
        match std::fs::symlink_metadata(&self.path) {
            Ok(metadata) if !metadata.file_type().is_file() => {
                return Err(
                    "Codex profile was replaced with a link or directory; it was preserved.".into(),
                );
            }
            Ok(_) => (),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(format!("Could not inspect Codex profile: {error}")),
        }
        let contents = std::fs::read(&self.path).map_err(|error| error.to_string())?;
        if contents != self.contents.as_bytes()
            && !self.is_ours_with_codex_state(&contents)
            && !is_codex_residue(&self.path)
        {
            return Err("Codex profile changed outside this session; it was preserved. Review switch.config.toml before starting another route.".into());
        }
        std::fs::remove_file(&self.path)
            .map_err(|error| format!("Could not remove generated Codex profile: {error}"))
    }
}

impl CodexProfile {
    /// The generated profile with only Codex's own `[tui]` state added to it.
    fn is_ours_with_codex_state(&self, contents: &[u8]) -> bool {
        let Ok(mut current) = std::str::from_utf8(contents)
            .map_err(drop)
            .and_then(|text| text.parse::<toml::Table>().map_err(drop))
        else {
            return false;
        };
        current.remove("tui");
        self.contents
            .parse::<toml::Table>()
            .is_ok_and(|ours| ours == current)
    }
}

/// A regular file left behind by an earlier Switchyard session (e.g. one that was killed
/// before cleanup): it selects the `switchyard-desktop` provider, so it is ours to replace.
fn is_stale_switchyard_profile(path: &std::path::Path) -> bool {
    let Ok(metadata) = std::fs::symlink_metadata(path) else {
        return false;
    };
    if !metadata.file_type().is_file() {
        return false;
    }
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| text.parse::<toml::Table>().ok())
        .is_some_and(|table| {
            table.get("model_provider").and_then(toml::Value::as_str) == Some("switchyard-desktop")
        })
}

/// A regular file holding nothing but Codex's `[tui]` UI state.
fn is_codex_residue(path: &std::path::Path) -> bool {
    let Ok(metadata) = std::fs::symlink_metadata(path) else {
        return false;
    };
    if !metadata.file_type().is_file() {
        return false;
    }
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| text.parse::<toml::Table>().ok())
        .is_some_and(|table| !table.is_empty() && table.keys().all(|key| key == "tui"))
}

impl Drop for CodexProfile {
    fn drop(&mut self) {
        let _ = self.remove();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Algorithm, RouteSettings};

    fn contents() -> String {
        RouteSettings {
            algorithm: Algorithm::Noop,
            ..Default::default()
        }
        .preview()
        .unwrap()
        .codex
    }

    #[test]
    fn profile_cleanup_preserves_the_user_configuration() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().into());
        std::fs::create_dir_all(locations.codex_home()).unwrap();
        let user = locations.codex_home().join("config.toml");
        std::fs::write(&user, "# exact user bytes\nmodel = 'own'\n").unwrap();
        let profile = CodexProfile::install(&locations, &contents()).unwrap();
        assert!(locations.codex_home().join("switch.config.toml").exists());
        drop(profile);
        assert!(!locations.codex_home().join("switch.config.toml").exists());
        assert_eq!(
            std::fs::read_to_string(user).unwrap(),
            "# exact user bytes\nmodel = 'own'\n"
        );
    }

    #[test]
    fn replaces_a_stale_switchyard_profile_but_never_a_foreign_one() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().into());
        let stale = CodexProfile::install(&locations, &contents()).unwrap();
        std::mem::forget(stale); // simulates a session killed before cleanup
        let profile = CodexProfile::install(&locations, &contents()).unwrap();
        assert_eq!(std::fs::read_to_string(&profile.path).unwrap(), contents());
        drop(profile);
        std::fs::write(locations.codex_home().join("switch.config.toml"), "model = \"x\"\n")
            .unwrap();
        assert!(CodexProfile::install(&locations, &contents()).is_err());
    }

    #[test]
    fn changed_and_malformed_profiles_survive_stop_and_drop() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().into());
        let mut profile = CodexProfile::install(&locations, &contents()).unwrap();
        std::fs::write(&profile.path, "foreign modified bytes").unwrap();
        assert!(profile.remove().is_err());
        drop(profile);
        assert_eq!(
            std::fs::read_to_string(locations.codex_home().join("switch.config.toml")).unwrap(),
            "foreign modified bytes"
        );
    }

    const RESIDUE: &str = "[tui.model_availability_nux]\n\"gpt-5.5\" = 4\n";

    #[test]
    fn replaces_codex_ui_residue_left_by_a_bare_profile_run() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().into());
        std::fs::create_dir_all(locations.codex_home()).unwrap();
        let path = locations.codex_home().join("switch.config.toml");
        std::fs::write(&path, RESIDUE).unwrap();
        let profile = CodexProfile::install(&locations, &contents()).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), contents());
        drop(profile);
        assert!(!path.exists());
    }

    #[test]
    fn stop_removes_the_profile_after_codex_adds_its_ui_state() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().into());
        let mut profile = CodexProfile::install(&locations, &contents()).unwrap();
        std::fs::write(&profile.path, format!("{}\n{RESIDUE}", contents())).unwrap();
        profile.remove().unwrap();
        assert!(!profile.path.exists());
        // Codex can also rewrite the file down to its own state once routing ends.
        let mut profile = CodexProfile::install(&locations, &contents()).unwrap();
        std::fs::write(&profile.path, RESIDUE).unwrap();
        profile.remove().unwrap();
        assert!(!profile.path.exists());
    }

    #[test]
    fn a_profile_with_other_content_is_still_never_replaced() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().into());
        std::fs::create_dir_all(locations.codex_home()).unwrap();
        let path = locations.codex_home().join("switch.config.toml");
        let foreign = format!("model = \"mine\"\n{RESIDUE}");
        std::fs::write(&path, &foreign).unwrap();
        assert!(CodexProfile::install(&locations, &contents()).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), foreign);
    }

    #[cfg(unix)]
    #[test]
    fn a_replaced_symlink_is_never_followed_or_deleted() {
        use std::os::unix::fs::symlink;
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().into());
        let mut profile = CodexProfile::install(&locations, &contents()).unwrap();
        let user = directory.path().join("user.toml");
        std::fs::write(&user, contents()).unwrap();
        std::fs::remove_file(&profile.path).unwrap();
        symlink(&user, &profile.path).unwrap();
        assert!(profile.remove().is_err());
        drop(profile);
        assert!(
            std::fs::symlink_metadata(locations.codex_home().join("switch.config.toml"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(std::fs::read_to_string(user).unwrap(), contents());
    }
}
