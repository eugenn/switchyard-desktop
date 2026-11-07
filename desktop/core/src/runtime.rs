use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::Result;

#[derive(Clone, Debug)]
pub struct RuntimeLayout {
    root: PathBuf,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeStatus {
    pub available: bool,
    pub platform: String,
    pub missing: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    litellm: String,
    fastapi: String,
    target: String,
    snapshot_commit: String,
    snapshot_manifest_sha256: String,
    development_only: bool,
}

impl RuntimeLayout {
    pub fn bundled(root: PathBuf) -> Self {
        Self { root }
    }

    pub(crate) fn root(&self) -> &PathBuf {
        &self.root
    }

    pub fn server(&self) -> PathBuf {
        self.root.join(if cfg!(windows) {
            "switchyard-server.exe"
        } else {
            "switchyard-server"
        })
    }

    pub fn python(&self) -> PathBuf {
        self.root.join("litellm").join(if cfg!(windows) {
            "python.exe"
        } else {
            "bin/python3.12"
        })
    }

    pub fn launcher(&self) -> PathBuf {
        self.root.join("litellm/launcher.py")
    }

    pub fn status(&self) -> RuntimeStatus {
        let mut missing = Vec::new();
        for (label, path) in [
            ("Switchyard server", self.server()),
            ("Python 3.12", self.python()),
            ("LiteLLM launcher", self.launcher()),
        ] {
            if !path.is_file() {
                missing.push(label.into());
            }
        }
        let expected: serde_json::Value =
            serde_json::from_str(include_str!("../../../vendor/switchyard-source.json"))
                .expect("Checked-in snapshot manifest is invalid");
        let snapshot_matches = std::fs::read(self.root.join("switchyard-source.json"))
            .is_ok_and(|bytes| bytes == include_bytes!("../../../vendor/switchyard-source.json"));
        match self.manifest() {
            Ok(manifest)
                if manifest.litellm == "1.97.0"
                    && manifest.fastapi == "0.136.3"
                    && manifest.target == env!("DESKTOP_TARGET")
                    && expected["commit"].as_str() == Some(manifest.snapshot_commit.as_str())
                    && snapshot_matches
                    && manifest.snapshot_manifest_sha256.len() == 64
                    && manifest.development_only => {}
            _ => missing
                .push("Matching runtime manifest (target, snapshot, pinned dependencies)".into()),
        }
        RuntimeStatus {
            available: missing.is_empty(),
            platform: format!("{} / {}", std::env::consts::OS, std::env::consts::ARCH),
            missing,
        }
    }

    fn manifest(&self) -> Result<Manifest> {
        let bytes = std::fs::read(self.root.join("runtime-manifest.json"))
            .map_err(|error| error.to_string())?;
        serde_json::from_slice(&bytes).map_err(|error| error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_manifest_must_match_the_checked_in_snapshot_and_build_target() {
        let directory = tempfile::tempdir().unwrap();
        let runtime = RuntimeLayout::bundled(directory.path().to_path_buf());
        for path in [runtime.server(), runtime.python(), runtime.launcher()] {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, "fixture").unwrap();
        }
        std::fs::write(
            directory.path().join("switchyard-source.json"),
            include_bytes!("../../../vendor/switchyard-source.json"),
        )
        .unwrap();
        let snapshot: serde_json::Value =
            serde_json::from_str(include_str!("../../../vendor/switchyard-source.json")).unwrap();
        let mut manifest = serde_json::json!({"target": env!("DESKTOP_TARGET"), "snapshotCommit": snapshot["commit"], "litellm": "1.97.0", "fastapi": "0.136.3", "snapshotManifestSha256": "0".repeat(64), "developmentOnly": true});
        let manifest_path = directory.path().join("runtime-manifest.json");
        std::fs::write(&manifest_path, manifest.to_string()).unwrap();
        assert!(runtime.status().available);
        manifest["target"] = "wrong-target".into();
        std::fs::write(&manifest_path, manifest.to_string()).unwrap();
        assert!(!runtime.status().available);
        manifest["target"] = env!("DESKTOP_TARGET").into();
        manifest["litellm"] = "unapproved-version".into();
        std::fs::write(&manifest_path, manifest.to_string()).unwrap();
        assert!(!runtime.status().available);
    }

    #[test]
    fn absent_runtime_never_falls_back_to_path_or_another_checkout() {
        let directory = tempfile::tempdir().unwrap();
        let runtime = RuntimeLayout::bundled(directory.path().join("missing"));
        assert!(!runtime.status().available);
        assert_eq!(runtime.status().missing.len(), 4);
        assert!(runtime.server().starts_with(directory.path()));
        assert!(runtime.python().starts_with(directory.path()));
    }
}
