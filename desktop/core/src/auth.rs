use std::{
    process::Command,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use serde::Serialize;

use crate::{Result, process::OwnedProcess};

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LoginStatus {
    pub pending: bool,
    pub signed_in: bool,
    pub code: Option<String>,
    pub verification_url: Option<String>,
    pub message: String,
}

pub(crate) struct LoginAttempt {
    process: OwnedProcess,
    output: Arc<Mutex<Vec<u8>>>,
    started: Instant,
}

impl LoginAttempt {
    pub(crate) fn begin(command: &mut Command) -> Result<Self> {
        let (process, output) = OwnedProcess::capture(command)?;
        Ok(Self {
            process,
            output,
            started: Instant::now(),
        })
    }

    pub(crate) fn status(&mut self) -> Result<LoginStatus> {
        if self.started.elapsed() > Duration::from_secs(15 * 60) {
            self.process.stop();
            return Err(
                "Sign-in timed out. Try again when you are ready to enter the device code.".into(),
            );
        }
        if let Some(success) = self.process.exit_success()? {
            return if success {
                Ok(LoginStatus { signed_in: true, message: "ChatGPT sign-in complete. Tokens are stored only in this app's private data directory.".into(), ..Default::default() })
            } else {
                Err("ChatGPT sign-in failed. Check your connection and retry.".into())
            };
        }
        let output = self
            .output
            .lock()
            .map_err(|_| "Could not read sign-in progress")?;
        let challenge = challenge(&String::from_utf8_lossy(&output));
        Ok(LoginStatus {
            pending: true,
            signed_in: false,
            verification_url: challenge
                .as_ref()
                .map(|_| "https://auth.openai.com/codex/device".into()),
            code: challenge,
            message: "Complete sign-in in your browser. Never share the device code.".into(),
        })
    }
}

fn challenge(output: &str) -> Option<String> {
    if !output
        .lines()
        .any(|line| line.trim_end_matches('\r') == "1) Visit https://auth.openai.com/codex/device")
    {
        return None;
    }
    output.lines().find_map(|line| {
        let code = line
            .trim_end_matches('\r')
            .strip_prefix("2) Enter code: ")?;
        (code.len() >= 4
            && code.len() <= 32
            && code.chars().all(|character| {
                character.is_ascii_uppercase() || character.is_ascii_digit() || character == '-'
            }))
        .then(|| code.to_owned())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_accepts_exact_known_device_url_and_valid_code() {
        assert_eq!(
            challenge("1) Visit https://auth.openai.com/codex/device\n2) Enter code: ABCD-1234\n"),
            Some("ABCD-1234".into())
        );
        assert_eq!(
            challenge(
                "1) Visit https://auth.openai.com/codex/device?bad=1\n2) Enter code: ABCD-1234\n"
            ),
            None
        );
        assert_eq!(
            challenge("1) Visit https://evil.invalid\n2) Enter code: ABCD-1234\n"),
            None
        );
        assert_eq!(
            challenge("1) Visit https://auth.openai.com/codex/device\n2) Enter code: <script>\n"),
            None
        );
    }
}
