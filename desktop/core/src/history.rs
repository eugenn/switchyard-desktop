use std::io::{Read, Seek, SeekFrom};

use serde_json::Value;

use crate::{Result, UserDataLocations};

impl UserDataLocations {
    pub fn rollout_session_ids(&self, session_ids: &[String]) -> Vec<String> {
        let mut days = Vec::new();
        for year in descending_directories(&self.codex_home().join("sessions")) {
            for month in descending_directories(&year) {
                for day in descending_directories(&month) {
                    days.push(day);
                    if days.len() == 60 {
                        break;
                    }
                }
                if days.len() == 60 {
                    break;
                }
            }
            if days.len() == 60 {
                break;
            }
        }
        let mut found = std::collections::BTreeSet::new();
        for day in days {
            for entry in std::fs::read_dir(day).into_iter().flatten().flatten() {
                if !entry.file_type().is_ok_and(|kind| kind.is_file()) {
                    continue;
                }
                let filename = entry.file_name();
                let filename = filename.to_string_lossy();
                for id in session_ids.iter().filter(|id| !id.is_empty()) {
                    if filename.ends_with(&format!("-{id}.jsonl")) {
                        found.insert(id.clone());
                    }
                }
            }
        }
        found.into_iter().collect()
    }

    pub fn routing_history(&self) -> Result<Vec<Value>> {
        let mut file = match std::fs::File::open(self.root().join("routing-log.jsonl")) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
            Err(_) => return Err("Could not read the app-owned routing log.".into()),
        };
        let size = file
            .metadata()
            .map_err(|_| "Could not inspect routing log.")?
            .len();
        let offset = size.saturating_sub(1024 * 1024);
        file.seek(SeekFrom::Start(offset))
            .map_err(|_| "Could not seek routing log.")?;
        let mut bytes = Vec::new();
        file.take(1024 * 1024)
            .read_to_end(&mut bytes)
            .map_err(|_| "Could not read routing log tail.")?;
        let mut lines = bytes.split(|byte| *byte == b'\n').collect::<Vec<_>>();
        if offset > 0 && !lines.is_empty() {
            lines.remove(0);
        }
        if !bytes.ends_with(b"\n") {
            lines.pop();
        }
        Ok(lines
            .into_iter()
            .rev()
            .filter_map(|line| serde_json::from_slice::<Value>(line).ok())
            .filter(|record| record.is_object() && record.get("outcome").is_none_or(Value::is_null))
            .take(500)
            .collect())
    }
}

fn descending_directories(path: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut directories: Vec<_> = std::fs::read_dir(path)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .map(|entry| entry.path())
        .collect();
    directories.sort_by(|left, right| right.cmp(left));
    directories
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rollout_lookup_uses_injected_codex_home_and_exact_session_suffix() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().join("app"));
        let day = locations.codex_home().join("sessions/2026/11/07");
        std::fs::create_dir_all(&day).unwrap();
        std::fs::write(day.join("rollout-2026-real.jsonl"), "{}").unwrap();
        std::fs::write(day.join("rollout-2026-partial-real.jsonl.backup"), "{}").unwrap();
        assert_eq!(
            locations.rollout_session_ids(&[
                "real".into(),
                "partial-real".into(),
                "missing".into()
            ]),
            vec!["real"]
        );
    }

    #[test]
    fn history_skips_outcomes_and_incomplete_rows_and_keeps_unknown_fields() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().to_path_buf());
        assert!(locations.routing_history().unwrap().is_empty());
        std::fs::write(
            directory.path().join("routing-log.jsonl"),
            concat!(
                "{\"model\":\"first\",\"new_field\":42}\n",
                "{\"outcome\":{\"status\":\"ok\"}}\n",
                "not json\n",
                "{\"model\":\"second\"}\n",
                "{\"model\":\"partial\"}"
            ),
        )
        .unwrap();
        let records = locations.routing_history().unwrap();
        assert_eq!(records.len(), 2);
        assert_eq!(records[0]["model"], "second");
        assert_eq!(records[1]["new_field"], 42);
    }

    #[test]
    fn tail_is_bounded_and_drops_partial_leading_row() {
        let directory = tempfile::tempdir().unwrap();
        let locations = UserDataLocations::injected(directory.path().to_path_buf());
        let row = format!("{{\"padding\":\"{}\"}}\n", "x".repeat(1024 * 1024));
        std::fs::write(
            directory.path().join("routing-log.jsonl"),
            format!("{row}{{\"model\":\"tail\"}}\n"),
        )
        .unwrap();
        assert_eq!(
            locations.routing_history().unwrap(),
            vec![serde_json::json!({"model":"tail"})]
        );
    }
}
