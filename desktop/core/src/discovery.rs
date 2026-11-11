use std::{
    process::Command,
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{Result, UserDataLocations, process::OwnedProcess};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AvailableModel {
    pub id: String,
    pub display_name: String,
    pub supports_images: bool,
    pub context_window: Option<u64>,
    pub efforts: Vec<String>,
}

pub async fn discover_models(
    locations: &UserDataLocations,
    executable: &str,
) -> Result<Vec<AvailableModel>> {
    let mut command = Command::new(if executable.trim().is_empty() {
        "codex"
    } else {
        executable
    });
    command
        .arg("app-server")
        .env("PATH", locations.tool_search_path())
        .env("CODEX_HOME", locations.codex_home());
    let input = [
        json!({"method":"initialize", "id":1, "params":{"clientInfo":{"name":"switchyard-desktop", "version":"0.1.0"}}}),
        json!({"method":"initialized", "params":{}}),
        json!({"method":"model/list", "id":2, "params":{"limit":100, "includeHidden":false}})
    ].iter().map(|message| format!("{message}\n")).collect::<String>();
    let (mut process, output) = OwnedProcess::capture_with_input(&mut command, 16 * 1024 * 1024)?;
    process.write_input(input.as_bytes())?;
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut models = loop {
        let response = {
            let bytes = output.lock().map_err(|_| "Could not read model catalog.")?;
            if bytes.len() >= 16 * 1024 * 1024 {
                return Err("Codex model catalog exceeded 16 MiB.".into());
            }
            bytes
                .split(|byte| *byte == b'\n')
                .filter_map(|line| serde_json::from_slice::<Value>(line).ok())
                .find(|response| response["id"] == 2)
        };
        if let Some(response) = response {
            process.stop();
            break parse_models(response)?;
        }
        if !process.is_running()? {
            return Err("Codex app-server exited before returning models. Check the selected Codex installation and sign-in.".into());
        }
        if Instant::now() >= deadline {
            return Err("Codex model discovery timed out after 30 seconds.".into());
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    let mut catalog = Command::new(if executable.trim().is_empty() {
        "codex"
    } else {
        executable
    });
    catalog
        .args(["debug", "models"])
        .env("PATH", locations.tool_search_path())
        .env("CODEX_HOME", locations.codex_home());
    if let Ok((mut process, output)) = OwnedProcess::capture_limited(&mut catalog, 16 * 1024 * 1024)
    {
        if process.wait_success(Duration::from_secs(30)).await.is_ok()
            && process.finish_output().await.is_ok()
        {
            if let Ok(bytes) = output.lock() {
                if let Ok(value) = serde_json::from_slice::<Value>(&bytes) {
                    apply_windows(&mut models, &value);
                }
            }
        }
    }
    Ok(models)
}

fn parse_models(response: Value) -> Result<Vec<AvailableModel>> {
    if response.get("error").is_some() {
        return Err(
            "Codex rejected model discovery. Sign in to the selected Codex account and retry."
                .into(),
        );
    }
    let result = &response["result"];
    if !result["nextCursor"].is_null() {
        return Err(
            "Codex returned a paginated catalog; refusing to show an incomplete model list.".into(),
        );
    }
    let entries = result["data"]
        .as_array()
        .ok_or("Codex returned an invalid model list.")?;
    let mut seen = std::collections::BTreeSet::new();
    let models = entries
        .iter()
        .filter(|entry| entry["hidden"] != true)
        .filter_map(|entry| {
            let id = entry["model"]
                .as_str()
                .or_else(|| entry["id"].as_str())?
                .trim();
            if id.is_empty() || !seen.insert(id.to_string()) {
                return None;
            }
            Some(AvailableModel {
                id: id.into(),
                display_name: entry["displayName"].as_str().unwrap_or(id).into(),
                supports_images: entry["inputModalities"]
                    .as_array()
                    .is_some_and(|modes| modes.iter().any(|mode| mode == "image")),
                context_window: None,
                efforts: vec![],
            })
        })
        .collect::<Vec<_>>();
    if models.is_empty() {
        return Err("Codex returned no available models.".into());
    }
    Ok(models)
}

fn apply_windows(models: &mut [AvailableModel], catalog: &Value) {
    let Some(entries) = catalog["models"].as_array() else {
        return;
    };
    for model in models {
        if let Some(entry) = entries.iter().find(|entry| entry["slug"] == model.id) {
            model.context_window = ["context_window", "max_context_window"]
                .iter()
                .filter_map(|key| entry[key].as_u64())
                .filter(|window| *window > 0)
                .max();
            model.efforts = entry["supported_reasoning_levels"]
                .as_array()
                .map(|levels| {
                    levels
                        .iter()
                        .filter_map(|level| level["effort"].as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filters_hidden_duplicates_and_keeps_image_and_window_metadata() {
        let mut models = parse_models(json!({"result":{"data":[{"model":"one", "displayName":"First", "inputModalities":["text","image"]}, {"model":"one"}, {"model":"hidden", "hidden":true}]}})).unwrap();
        apply_windows(
            &mut models,
            &json!({"models":[{"slug":"one", "context_window":10000, "max_context_window":20000, "supported_reasoning_levels":[{"effort":"high"}]}]}),
        );
        assert_eq!(models.len(), 1);
        assert!(models[0].supports_images);
        assert_eq!(models[0].context_window, Some(20000));
        assert_eq!(models[0].efforts, ["high"]);
        assert!(parse_models(json!({"result":{"data":[], "nextCursor":"more"}})).is_err());
    }
}

#[cfg(all(test, unix))]
mod process_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[tokio::test]
    async fn discovery_uses_injected_codex_home_and_keeps_stdin_open_until_reply() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().join("app-data"));
        let executable = directory.path().join("mock-codex");
        let script = format!(
            r#"#!/bin/sh
if [ "$CODEX_HOME" != '{}' ]; then exit 2; fi
if [ "$1" = 'debug' ]; then
  printf '%s\n' '{{"models":[{{"slug":"test-model","context_window":8192}}]}}'
  exit 0
fi
IFS= read -r initialize
IFS= read -r initialized
IFS= read -r request
printf '%s\n' '{{"id":2,"result":{{"data":[{{"model":"test-model","inputModalities":["text","image"]}}]}}}}'
IFS= read -r keep_open
"#,
            locations.codex_home().display()
        );
        std::fs::write(&executable, script).unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let models = discover_models(&locations, executable.to_str().unwrap())
            .await
            .unwrap();
        assert_eq!(models[0].id, "test-model");
        assert_eq!(models[0].context_window, Some(8192));
        assert!(models[0].supports_images);
        assert!(!locations.root().exists());
    }
}
