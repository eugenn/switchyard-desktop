//! Model provider connections: what the user has connected, how, and which
//! models each connection offers. Secrets stay in the credential vault; this
//! store keeps only display hints and cached model lists.

use std::{
    collections::BTreeMap,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{AvailableModel, Result, UserDataLocations};

const FILE: &str = "connections.json";

/// Connections shown on the Providers page, in order.
pub const PROVIDER_CONNECTIONS: [&str; 5] =
    ["chatgpt", "openai", "anthropic", "openrouter", "typesafe"];

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ConnectionRecord {
    /// Last four characters of the saved key, recorded when it was saved, so the
    /// vault is never read just to show which key is in use.
    pub key_hint: String,
    pub models: Vec<AvailableModel>,
    /// Unix seconds of the last successful model list.
    pub refreshed_at: Option<u64>,
    /// Unix seconds of the last check, successful or not.
    pub checked_at: Option<u64>,
    pub latency_ms: Option<u64>,
    /// The last check's failure, empty after a success.
    pub error: String,
}

/// A connection as the app shows it.
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionView {
    pub id: String,
    pub connected: bool,
    #[serde(flatten)]
    pub record: ConnectionRecord,
}

pub(crate) fn load(locations: &UserDataLocations) -> Result<BTreeMap<String, ConnectionRecord>> {
    match std::fs::read(locations.root().join(FILE)) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map_err(|error| format!("Could not read saved connections: {error}")),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(BTreeMap::new()),
        Err(error) => Err(format!("Could not read saved connections: {error}")),
    }
}

pub(crate) fn save(
    locations: &UserDataLocations,
    records: &BTreeMap<String, ConnectionRecord>,
) -> Result<()> {
    locations.write(
        FILE,
        &serde_json::to_string_pretty(records).map_err(|error| error.to_string())?,
    )
}

pub(crate) fn key_hint(key: &str) -> String {
    let characters: Vec<char> = key.trim().chars().collect();
    if characters.len() < 8 {
        return String::new();
    }
    characters[characters.len() - 4..].iter().collect()
}

pub(crate) fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or_default()
}

/// Fetches a provider's model list with its key. The list endpoints are free,
/// so this doubles as the connection test.
pub async fn fetch_models(
    client: &reqwest::Client,
    connection: &str,
    key: &str,
) -> Result<(Vec<AvailableModel>, u64)> {
    let request = match connection {
        "openai" => client
            .get("https://api.openai.com/v1/models")
            .bearer_auth(key),
        "anthropic" => client
            .get("https://api.anthropic.com/v1/models?limit=1000")
            .header("x-api-key", key)
            .header("anthropic-version", "2023-06-01"),
        "openrouter" => client
            .get("https://openrouter.ai/api/v1/models")
            .bearer_auth(key),
        _ => return Err("This connection has no model list.".into()),
    };
    let began = Instant::now();
    let response = request
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .map_err(|error| format!("Could not reach the provider: {error}"))?;
    let status = response.status();
    let body = response
        .text()
        .await
        .map_err(|error| format!("Could not read the provider's answer: {error}"))?;
    let latency = began.elapsed().as_millis() as u64;
    if status.as_u16() == 401 || status.as_u16() == 403 {
        return Err("The provider rejected the API key.".into());
    }
    if !status.is_success() {
        return Err(format!("The provider answered {status}."));
    }
    Ok((parse_models(connection, &body)?, latency))
}

/// Reads a `/models` answer. OpenAI lists non-chat models too, which are left out.
pub(crate) fn parse_models(connection: &str, body: &str) -> Result<Vec<AvailableModel>> {
    let value: Value =
        serde_json::from_str(body).map_err(|_| "The provider sent an unreadable model list.")?;
    let entries = value["data"]
        .as_array()
        .ok_or("The provider sent an unreadable model list.")?;
    let mut models: Vec<AvailableModel> = entries
        .iter()
        .filter_map(|entry| {
            let id = entry["id"].as_str()?.to_owned();
            if id.is_empty() || id.len() > 200 {
                return None;
            }
            if connection == "openai"
                && [
                    "embedding",
                    "tts",
                    "whisper",
                    "dall-e",
                    "moderation",
                    "transcribe",
                    "image",
                    "audio",
                    "realtime",
                    "search",
                    "babbage",
                    "davinci",
                ]
                .iter()
                .any(|skip| id.contains(skip))
            {
                return None;
            }
            let display_name = entry["display_name"]
                .as_str()
                .or_else(|| entry["name"].as_str())
                .unwrap_or(&id)
                .to_owned();
            let supports_images = entry["architecture"]["input_modalities"]
                .as_array()
                .is_some_and(|modalities| modalities.iter().any(|item| item == "image"));
            let context_window = entry["context_length"]
                .as_u64()
                .or_else(|| entry["max_input_tokens"].as_u64());
            Some(AvailableModel {
                id,
                display_name,
                supports_images,
                context_window,
                efforts: Vec::new(),
            })
        })
        .collect();
    models.sort_by(|a, b| a.id.cmp(&b.id));
    models.dedup_by(|a, b| a.id == b.id);
    models.truncate(1000);
    Ok(models)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_lists_parse_per_provider_and_skip_non_chat_models() {
        let openai = r#"{"data":[{"id":"gpt-5.1"},{"id":"text-embedding-3-large"},{"id":"gpt-4o-mini-tts"}]}"#;
        assert_eq!(
            parse_models("openai", openai)
                .unwrap()
                .iter()
                .map(|model| model.id.as_str())
                .collect::<Vec<_>>(),
            ["gpt-5.1"]
        );
        let anthropic = r#"{"data":[{"id":"claude-opus-4-8","display_name":"Claude Opus 4.8","type":"model"}]}"#;
        let models = parse_models("anthropic", anthropic).unwrap();
        assert_eq!(models[0].display_name, "Claude Opus 4.8");
        let openrouter = r#"{"data":[{"id":"z-ai/glm-5.2","name":"GLM 5.2","context_length":200000,"architecture":{"input_modalities":["text","image"]}}]}"#;
        let models = parse_models("openrouter", openrouter).unwrap();
        assert_eq!(models[0].context_window, Some(200000));
        assert!(models[0].supports_images);
        assert!(models[0].efforts.is_empty());
        assert!(parse_models("openai", "<html>").is_err());
    }

    #[test]
    fn key_hints_never_reveal_short_keys() {
        assert_eq!(key_hint("sk-test-abcd1234"), "1234");
        assert_eq!(key_hint("short"), "");
    }

    #[test]
    fn records_round_trip_through_the_sandbox() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().join("app"));
        assert!(load(&locations).unwrap().is_empty());
        let mut records = BTreeMap::new();
        records.insert(
            "anthropic".to_owned(),
            ConnectionRecord {
                key_hint: "1234".into(),
                ..Default::default()
            },
        );
        save(&locations, &records).unwrap();
        assert_eq!(load(&locations).unwrap(), records);
        assert!(
            !std::fs::read_to_string(locations.root().join(FILE))
                .unwrap()
                .contains("sk-")
        );
    }
}
