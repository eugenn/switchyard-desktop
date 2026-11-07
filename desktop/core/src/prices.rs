//! LiteLLM's list prices, refreshed daily with a cached or bundled fallback.
//! Model price table: reserved keys are dropped,
//! only numeric `*cost*` fields are kept, ids are lower-cased and each entry's
//! `aliases` become ids of their own unless a real entry already claims them.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::Value;

use crate::{Result, RuntimeLayout, UserDataLocations};

pub type ModelPrices = BTreeMap<String, BTreeMap<String, f64>>;

const RESERVED: [&str; 2] = ["sample_spec", "fallback_generalizations"];
const UPSTREAM: &str =
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";

pub struct ModelPriceReader {
    runtime: RuntimeLayout,
    locations: UserDataLocations,
    remote_url: Option<String>,
}

impl ModelPriceReader {
    pub fn new(runtime: RuntimeLayout, locations: UserDataLocations) -> Self {
        Self {
            runtime,
            locations,
            remote_url: Some(UPSTREAM.into()),
        }
    }

    fn bundled(&self) -> Option<PriceMap> {
        PriceMap::read(&self.runtime.price_map_path())
    }

    fn cached(&self) -> Option<PriceMap> {
        let cached = PriceMap::read(&self.locations.root().join("model-prices.json"))?;
        cached.acceptable(self.bundled().as_ref()).then_some(cached)
    }

    pub fn local_prices(&self) -> Result<ModelPrices> {
        self.cached()
            .or_else(|| self.bundled())
            .map(|map| map.prices)
            .ok_or_else(|| "LiteLLM's price map is unavailable.".into())
    }

    fn needs_download(&self) -> bool {
        self.remote_url.is_some()
            && (self.cached().is_none()
                || std::fs::metadata(self.locations.root().join("model-prices.json"))
                    .and_then(|metadata| metadata.modified())
                    .ok()
                    .and_then(|modified| modified.elapsed().ok())
                    .is_none_or(|age| age > Duration::from_secs(24 * 60 * 60)))
    }

    pub async fn refresh_prices(&self) -> Result<ModelPrices> {
        if self.needs_download() {
            if let Some(map) = self.download().await {
                return Ok(map.prices);
            }
        }
        self.local_prices()
    }

    async fn download(&self) -> Option<PriceMap> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(20))
            .build()
            .ok()?;
        let response = client
            .get(self.remote_url.as_ref()?)
            .send()
            .await
            .ok()?
            .error_for_status()
            .ok()?;
        let text = response.text().await.ok()?;
        let map = PriceMap::parse(&text).ok()?;
        if !map.acceptable(self.bundled().as_ref()) {
            return None;
        }
        let _ = self.locations.write("model-prices.json", &text);
        Some(map)
    }
}

struct PriceMap {
    prices: ModelPrices,
    model_count: usize,
}

impl PriceMap {
    fn read(path: &std::path::Path) -> Option<Self> {
        Self::parse(&std::fs::read_to_string(path).ok()?).ok()
    }

    fn parse(text: &str) -> Result<Self> {
        let root: serde_json::Map<String, Value> =
            serde_json::from_str(text).map_err(|_| "Could not read LiteLLM's price map.")?;
        let model_count = root
            .iter()
            .filter(|(id, entry)| !RESERVED.contains(&id.as_str()) && entry.is_object())
            .count();
        Ok(Self {
            prices: parse_price_map(text)?,
            model_count,
        })
    }

    fn acceptable(&self, bundled: Option<&Self>) -> bool {
        self.model_count >= 50
            && bundled.is_none_or(|bundled| self.model_count * 2 >= bundled.model_count)
    }
}

impl RuntimeLayout {
    pub fn price_map_path(&self) -> PathBuf {
        let litellm = self.root().join("litellm");
        let site_packages = if cfg!(windows) {
            litellm.join("Lib").join("site-packages")
        } else {
            litellm.join("lib").join("python3.12").join("site-packages")
        };
        site_packages
            .join("litellm")
            .join("model_prices_and_context_window_backup.json")
    }

    pub fn model_prices(&self) -> Result<ModelPrices> {
        let text = std::fs::read_to_string(self.price_map_path())
            .map_err(|_| "LiteLLM's bundled price map is missing from the runtime.")?;
        parse_price_map(&text)
    }
}

pub fn parse_price_map(text: &str) -> Result<ModelPrices> {
    let root = serde_json::from_str::<serde_json::Map<String, Value>>(text)
        .map_err(|_| "Could not read LiteLLM's bundled price map.")?;
    let mut prices = ModelPrices::new();
    let mut aliases = Vec::new();
    for (id, entry) in &root {
        if RESERVED.contains(&id.as_str()) {
            continue;
        }
        let Some(entry) = entry.as_object() else {
            continue;
        };
        let costs = entry
            .iter()
            .filter(|(key, _)| key.contains("cost"))
            .filter_map(|(key, value)| number(value).map(|number| (key.clone(), number)))
            .collect::<BTreeMap<_, _>>();
        for alias in entry
            .get("aliases")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            aliases.push((alias.to_lowercase(), costs.clone()));
        }
        prices.entry(id.to_lowercase()).or_insert(costs);
    }
    for (alias, costs) in aliases {
        prices.entry(alias).or_insert(costs);
    }
    Ok(prices)
}

fn number(value: &Value) -> Option<f64> {
    match value {
        Value::Number(number) => number.as_f64(),
        Value::String(text) => text.trim().parse().ok(),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(count: usize) -> String {
        let entries: serde_json::Map<String, Value> = (0..count)
            .map(|index| {
                (
                    format!("model-{index}"),
                    serde_json::json!({"input_cost_per_token": 1, "output_cost_per_token": 2}),
                )
            })
            .collect();
        serde_json::to_string(&entries).unwrap()
    }

    #[test]
    fn cache_requires_a_complete_price_map_and_falls_back_to_bundled() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().join("app"));
        let runtime = RuntimeLayout::bundled(directory.path().join("runtime"));
        std::fs::create_dir_all(runtime.price_map_path().parent().unwrap()).unwrap();
        std::fs::write(runtime.price_map_path(), fixture(120)).unwrap();
        locations.write("model-prices.json", &fixture(59)).unwrap();
        let reader = ModelPriceReader {
            runtime,
            locations: locations.clone(),
            remote_url: None,
        };
        assert_eq!(reader.local_prices().unwrap().len(), 120);
        locations.write("model-prices.json", &fixture(60)).unwrap();
        assert_eq!(reader.local_prices().unwrap().len(), 60);
        locations.write("model-prices.json", "not json").unwrap();
        assert_eq!(reader.local_prices().unwrap().len(), 120);
    }

    #[tokio::test]
    async fn refresh_downloads_and_caches_valid_prices_and_keeps_them_offline() {
        use std::io::{Read, Write};
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().join("app"));
        let runtime = RuntimeLayout::bundled(directory.path().join("runtime"));
        std::fs::create_dir_all(runtime.price_map_path().parent().unwrap()).unwrap();
        std::fs::write(runtime.price_map_path(), fixture(100)).unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0; 2048];
            stream.read(&mut request).unwrap();
            let body = fixture(101);
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .unwrap();
        });
        let reader = ModelPriceReader {
            runtime,
            locations: locations.clone(),
            remote_url: Some(format!("http://{address}")),
        };
        assert_eq!(reader.local_prices().unwrap().len(), 100);
        assert_eq!(reader.refresh_prices().await.unwrap().len(), 101);
        server.join().unwrap();
        assert_eq!(reader.local_prices().unwrap().len(), 101);
        assert!(!reader.needs_download());
        assert_eq!(reader.refresh_prices().await.unwrap().len(), 101);
    }

    #[test]
    fn keeps_costs_and_aliases_and_drops_reserved_keys() {
        let prices = parse_price_map(
            r#"{
                "sample_spec": {"input_cost_per_token": 1},
                "GPT-X": {"input_cost_per_token": 0.000002, "output_cost_per_token": "0.000008",
                          "max_tokens": 9, "supports_vision": true, "aliases": ["gpt-x-latest", "taken"]},
                "taken": {"mode": "chat"}
            }"#,
        )
        .unwrap();
        assert!(!prices.contains_key("sample_spec"));
        assert_eq!(prices["gpt-x"]["output_cost_per_token"], 0.000008);
        assert!(!prices["gpt-x"].contains_key("max_tokens"));
        assert_eq!(prices["gpt-x-latest"], prices["gpt-x"]);
        assert!(prices["taken"].is_empty());
    }

    #[test]
    fn missing_price_map_is_reported_not_guessed() {
        let directory = tempfile::tempdir().unwrap();
        let runtime = RuntimeLayout::bundled(directory.path().to_path_buf());
        assert!(runtime.model_prices().is_err());
    }
}
