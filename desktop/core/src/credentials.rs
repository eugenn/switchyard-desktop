use std::{collections::HashMap, sync::Mutex};

use crate::Result;

/// A credential the app keeps in the system vault. Each one has its own vault entry,
/// so removing or replacing one never touches another.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum Credential {
    Typesafe,
    Anthropic,
}

impl Credential {
    fn service(self) -> &'static str {
        match self {
            Credential::Typesafe => "dev.switchyard.desktop.preview.typesafe",
            Credential::Anthropic => "dev.switchyard.desktop.preview.anthropic",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Credential::Typesafe => "TypeSafe",
            Credential::Anthropic => "Anthropic",
        }
    }
}

const ACCOUNT: &str = "api-key";

pub struct CredentialVault {
    memory: Option<Mutex<HashMap<Credential, String>>>,
}

impl CredentialVault {
    pub fn isolated() -> Self {
        Self {
            memory: Some(Mutex::new(HashMap::new())),
        }
    }

    pub fn current() -> Self {
        let test = cfg!(test)
            || std::env::current_exe().ok().is_some_and(|executable| {
                executable.parent().and_then(std::path::Path::file_name)
                    == Some(std::ffi::OsStr::new("deps"))
            });
        if test {
            Self::isolated()
        } else {
            Self { memory: None }
        }
    }

    pub fn set_typesafe_key(&self, key: &str) -> Result<()> {
        self.set(Credential::Typesafe, key)
    }

    pub fn has_typesafe_key(&self) -> Result<bool> {
        self.typesafe_key().map(|key| key.is_some())
    }

    pub(crate) fn typesafe_key(&self) -> Result<Option<String>> {
        self.get(Credential::Typesafe)
    }

    pub fn set_anthropic_key(&self, key: &str) -> Result<()> {
        self.set(Credential::Anthropic, key)
    }

    pub fn has_anthropic_key(&self) -> Result<bool> {
        self.anthropic_key().map(|key| key.is_some())
    }

    pub(crate) fn anthropic_key(&self) -> Result<Option<String>> {
        self.get(Credential::Anthropic)
    }

    fn set(&self, credential: Credential, key: &str) -> Result<()> {
        if key.len() > 2048 || key.bytes().any(|byte| !byte.is_ascii_graphic()) {
            return Err(
                "Enter an API key up to 2048 characters without spaces or control characters."
                    .into(),
            );
        }
        if let Some(memory) = &self.memory {
            let mut memory = memory
                .lock()
                .map_err(|_| "Could not access isolated credentials.")?;
            if key.is_empty() {
                memory.remove(&credential);
            } else {
                memory.insert(credential, key.into());
            }
            return Ok(());
        }
        platform_set(credential, key)
    }

    fn get(&self, credential: Credential) -> Result<Option<String>> {
        if let Some(memory) = &self.memory {
            return memory
                .lock()
                .map(|memory| memory.get(&credential).cloned())
                .map_err(|_| "Could not access isolated credentials.".into());
        }
        platform_get(credential)
    }
}

#[cfg(target_os = "macos")]
fn platform_set(credential: Credential, key: &str) -> Result<()> {
    use security_framework::passwords::{delete_generic_password, set_generic_password};
    let result = if key.is_empty() {
        delete_generic_password(credential.service(), ACCOUNT)
    } else {
        set_generic_password(credential.service(), ACCOUNT, key.as_bytes())
    };
    match result {
        Ok(()) => Ok(()),
        Err(error) if key.is_empty() && error.code() == -25300 => Ok(()),
        Err(_) => Err(format!(
            "Keychain did not save the {} key. Check access permissions.",
            credential.label()
        )),
    }
}

#[cfg(target_os = "macos")]
fn platform_get(credential: Credential) -> Result<Option<String>> {
    match security_framework::passwords::get_generic_password(credential.service(), ACCOUNT) {
        Ok(bytes) => String::from_utf8(bytes)
            .map(Some)
            .map_err(|_| format!("Invalid {} credential encoding.", credential.label())),
        Err(error) if error.code() == -25300 => Ok(None),
        Err(_) => Err(format!(
            "Keychain did not allow access to the {} key.",
            credential.label()
        )),
    }
}

#[cfg(windows)]
fn platform_set(credential: Credential, key: &str) -> Result<()> {
    use windows_sys::Win32::{Foundation::ERROR_NOT_FOUND, Security::Credentials::*};
    let mut target: Vec<u16> = credential.service().encode_utf16().chain(Some(0)).collect();
    if key.is_empty() {
        if unsafe { CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0) } == 0
            && std::io::Error::last_os_error().raw_os_error() != Some(ERROR_NOT_FOUND as i32)
        {
            return Err(format!(
                "Credential Manager did not delete the {} key.",
                credential.label()
            ));
        }
        return Ok(());
    }
    let mut user: Vec<u16> = ACCOUNT.encode_utf16().chain(Some(0)).collect();
    let mut bytes = key.as_bytes().to_vec();
    let credential_record = CREDENTIALW {
        Type: CRED_TYPE_GENERIC,
        TargetName: target.as_mut_ptr(),
        CredentialBlobSize: bytes.len() as u32,
        CredentialBlob: bytes.as_mut_ptr(),
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        UserName: user.as_mut_ptr(),
        ..Default::default()
    };
    if unsafe { CredWriteW(&credential_record, 0) } == 0 {
        return Err(format!(
            "Credential Manager did not save the {} key.",
            credential.label()
        ));
    }
    Ok(())
}

#[cfg(windows)]
fn platform_get(credential: Credential) -> Result<Option<String>> {
    use windows_sys::Win32::{Foundation::ERROR_NOT_FOUND, Security::Credentials::*};
    let target: Vec<u16> = credential.service().encode_utf16().chain(Some(0)).collect();
    let mut record = std::ptr::null_mut();
    if unsafe { CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut record) } == 0 {
        return if std::io::Error::last_os_error().raw_os_error() == Some(ERROR_NOT_FOUND as i32) {
            Ok(None)
        } else {
            Err(format!(
                "Credential Manager did not allow access to the {} key.",
                credential.label()
            ))
        };
    }
    let result = unsafe {
        if (*record).CredentialBlobSize == 0
            || (*record).CredentialBlobSize > 2048
            || (*record).CredentialBlob.is_null()
        {
            Err(format!("Invalid {} credential size.", credential.label()))
        } else {
            String::from_utf8(
                std::slice::from_raw_parts(
                    (*record).CredentialBlob,
                    (*record).CredentialBlobSize as usize,
                )
                .to_vec(),
            )
            .map(Some)
            .map_err(|_| format!("Invalid {} credential encoding.", credential.label()))
        }
    };
    unsafe {
        CredFree(record.cast());
    }
    result
}

#[cfg(not(any(target_os = "macos", windows)))]
fn platform_set(_: Credential, _: &str) -> Result<()> {
    Err("No supported credential vault on this platform.".into())
}
#[cfg(not(any(target_os = "macos", windows)))]
fn platform_get(_: Credential) -> Result<Option<String>> {
    Err("No supported credential vault on this platform.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credentials_are_isolated_and_cannot_leak_between_vaults() {
        let vault = CredentialVault::current();
        let another = CredentialVault::current();
        assert!(!vault.has_typesafe_key().unwrap());
        vault
            .set_typesafe_key("mock-secret-not-a-real-key")
            .unwrap();
        assert!(vault.has_typesafe_key().unwrap());
        assert!(!another.has_typesafe_key().unwrap());
        assert!(vault.set_typesafe_key("bad\nkey").is_err());
        assert_eq!(
            vault.typesafe_key().unwrap().as_deref(),
            Some("mock-secret-not-a-real-key")
        );
        vault.set_typesafe_key("").unwrap();
        assert!(!vault.has_typesafe_key().unwrap());
    }

    #[test]
    fn each_credential_has_its_own_slot() {
        let vault = CredentialVault::current();
        vault
            .set_anthropic_key("mock-anthropic-not-a-real-key")
            .unwrap();
        assert!(vault.has_anthropic_key().unwrap());
        assert!(!vault.has_typesafe_key().unwrap());
        vault
            .set_typesafe_key("mock-typesafe-not-a-real-key")
            .unwrap();
        vault.set_anthropic_key("").unwrap();
        assert!(!vault.has_anthropic_key().unwrap());
        assert_eq!(
            vault.typesafe_key().unwrap().as_deref(),
            Some("mock-typesafe-not-a-real-key")
        );
        assert!(vault.set_anthropic_key("two words").is_err());
        assert!(vault.set_anthropic_key(&"k".repeat(2049)).is_err());
    }
}
