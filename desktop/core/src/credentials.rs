#![cfg_attr(not(any(target_os = "macos", windows)), allow(dead_code))]

use std::{
    collections::HashMap,
    sync::{Mutex, MutexGuard},
};

use crate::Result;

/// A credential the app keeps in the system vault.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum Credential {
    Typesafe,
    Anthropic,
}

impl Credential {
    const ALL: [Credential; 2] = [Credential::Typesafe, Credential::Anthropic];

    fn name(self) -> &'static str {
        match self {
            Credential::Typesafe => "typesafe",
            Credential::Anthropic => "anthropic",
        }
    }

    fn from_name(name: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|credential| credential.name() == name)
    }

    /// The per-credential vault entry. Windows keeps one entry per credential; macOS
    /// used these before all keys moved into one Keychain item and migrates them.
    fn entry(self) -> &'static str {
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

const ENTRY_ACCOUNT: &str = "api-key";

type Secrets = HashMap<Credential, String>;

/// API keys in the operating system's credential vault.
///
/// The vault may ask the user to approve access (macOS Keychain does whenever the
/// running build is not the one that saved the item). To keep that to one approval per
/// launch at most, and none until a key is really needed:
/// - presence checks never read a secret,
/// - every secret lives in one vault item on macOS, so one approval covers all keys,
/// - secrets read once are kept in memory for the life of the process.
pub struct CredentialVault {
    store: Store,
}

enum Store {
    /// Test vault: never touches the system vault.
    Isolated(Mutex<Secrets>),
    /// System vault with the secrets read so far (`None` until first read).
    System(Mutex<Option<Secrets>>),
}

fn lock<T>(mutex: &Mutex<T>) -> Result<MutexGuard<'_, T>> {
    mutex
        .lock()
        .map_err(|_| "Could not access saved credentials.".into())
}

impl CredentialVault {
    pub fn isolated() -> Self {
        Self {
            store: Store::Isolated(Mutex::new(HashMap::new())),
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
            Self {
                store: Store::System(Mutex::new(None)),
            }
        }
    }

    pub fn set_typesafe_key(&self, key: &str) -> Result<()> {
        self.set(Credential::Typesafe, key)
    }

    pub fn has_typesafe_key(&self) -> Result<bool> {
        self.has(Credential::Typesafe)
    }

    pub(crate) fn typesafe_key(&self) -> Result<Option<String>> {
        self.get(Credential::Typesafe)
    }

    pub fn set_anthropic_key(&self, key: &str) -> Result<()> {
        self.set(Credential::Anthropic, key)
    }

    pub fn has_anthropic_key(&self) -> Result<bool> {
        self.has(Credential::Anthropic)
    }

    pub(crate) fn anthropic_key(&self) -> Result<Option<String>> {
        self.get(Credential::Anthropic)
    }

    /// Presence check that never reads a secret, so it cannot ask for approval.
    fn has(&self, credential: Credential) -> Result<bool> {
        match &self.store {
            Store::Isolated(memory) => Ok(lock(memory)?.contains_key(&credential)),
            Store::System(cache) => {
                if let Some(secrets) = lock(cache)?.as_ref() {
                    return Ok(secrets.contains_key(&credential));
                }
                Ok(platform::present()?.contains(&credential))
            }
        }
    }

    fn get(&self, credential: Credential) -> Result<Option<String>> {
        match &self.store {
            Store::Isolated(memory) => Ok(lock(memory)?.get(&credential).cloned()),
            Store::System(cache) => {
                let mut cache = lock(cache)?;
                if cache.is_none() {
                    *cache = Some(platform::load()?);
                }
                Ok(cache
                    .as_ref()
                    .and_then(|secrets| secrets.get(&credential).cloned()))
            }
        }
    }

    fn set(&self, credential: Credential, key: &str) -> Result<()> {
        if key.len() > 2048 || key.bytes().any(|byte| !byte.is_ascii_graphic()) {
            return Err(
                "Enter an API key up to 2048 characters without spaces or control characters."
                    .into(),
            );
        }
        let update = |secrets: &mut Secrets| {
            if key.is_empty() {
                secrets.remove(&credential);
            } else {
                secrets.insert(credential, key.into());
            }
        };
        match &self.store {
            Store::Isolated(memory) => {
                update(&mut *lock(memory)?);
                Ok(())
            }
            Store::System(cache) => {
                let mut cache = lock(cache)?;
                let mut secrets = match cache.as_ref() {
                    Some(secrets) => secrets.clone(),
                    // Nothing saved yet: no need to read (and ask for) anything.
                    None if platform::present()?.is_empty() => Secrets::new(),
                    None => platform::load()?,
                };
                update(&mut secrets);
                platform::save(&secrets, credential)?;
                *cache = Some(secrets);
                Ok(())
            }
        }
    }
}

/// Serialized form of all keys in one vault item: a JSON object keyed by name.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn encode(secrets: &Secrets) -> Vec<u8> {
    let object: serde_json::Map<String, serde_json::Value> = secrets
        .iter()
        .map(|(credential, key)| (credential.name().into(), key.clone().into()))
        .collect();
    serde_json::Value::Object(object).to_string().into_bytes()
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn decode(bytes: &[u8]) -> Result<Secrets> {
    let invalid = || "The saved API keys could not be read.".to_string();
    let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    let object = value.as_object().ok_or_else(invalid)?;
    let mut secrets = Secrets::new();
    for (name, key) in object {
        if let (Some(credential), Some(key)) = (Credential::from_name(name), key.as_str()) {
            secrets.insert(credential, key.into());
        }
    }
    Ok(secrets)
}

/// Names of the saved keys, kept in a non-secret attribute of the vault item so that
/// presence can be checked without reading (and asking for) the secret.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn names(secrets: &Secrets) -> String {
    let mut names: Vec<&str> = secrets.keys().map(|credential| credential.name()).collect();
    names.sort_unstable();
    names.join(",")
}

#[cfg(target_os = "macos")]
mod platform {
    use std::collections::{HashMap, HashSet};

    use core_foundation::data::CFData;
    use security_framework::{
        item::{ItemAddOptions, ItemAddValue, ItemClass, ItemSearchOptions},
        passwords::{delete_generic_password, get_generic_password},
    };

    use super::{Credential, ENTRY_ACCOUNT, Secrets, decode, encode, names};
    use crate::Result;

    const SERVICE: &str = "dev.switchyard.desktop.preview.credentials";
    const ACCOUNT: &str = "api-keys";
    const LABEL: &str = "Switchyard Desktop API keys";
    const NOT_FOUND: i32 = -25300;
    /// `kSecAttrComment` as it appears in an attribute dictionary.
    const COMMENT: &str = "icmt";

    const READ_ERROR: &str = "Keychain did not allow access to the saved API keys.";
    const SAVE_ERROR: &str = "Keychain did not save the API keys. Check access permissions.";

    /// Attributes of an item, without its secret. Reading attributes needs no approval.
    fn attributes(service: &str, account: &str) -> Result<Option<HashMap<String, String>>> {
        match ItemSearchOptions::new()
            .class(ItemClass::generic_password())
            .service(service)
            .account(account)
            .load_attributes(true)
            .search()
        {
            Ok(found) => Ok(Some(
                found
                    .first()
                    .and_then(|item| item.simplify_dict())
                    .unwrap_or_default(),
            )),
            Err(error) if error.code() == NOT_FOUND => Ok(None),
            Err(_) => Err(READ_ERROR.into()),
        }
    }

    pub(super) fn present() -> Result<HashSet<Credential>> {
        if let Some(attributes) = attributes(SERVICE, ACCOUNT)? {
            return Ok(attributes
                .get(COMMENT)
                .map(|names| names.split(',').filter_map(Credential::from_name).collect())
                .unwrap_or_default());
        }
        let mut present = HashSet::new();
        for credential in Credential::ALL {
            if attributes(credential.entry(), ENTRY_ACCOUNT)?.is_some() {
                present.insert(credential);
            }
        }
        Ok(present)
    }

    pub(super) fn load() -> Result<Secrets> {
        match get_generic_password(SERVICE, ACCOUNT) {
            Ok(bytes) => decode(&bytes),
            Err(error) if error.code() == NOT_FOUND => migrate(),
            Err(_) => Err(READ_ERROR.into()),
        }
    }

    /// Moves keys from the old per-credential items into the single item. Runs once:
    /// afterwards the old items are gone.
    fn migrate() -> Result<Secrets> {
        let mut secrets = Secrets::new();
        for credential in Credential::ALL {
            match get_generic_password(credential.entry(), ENTRY_ACCOUNT) {
                Ok(bytes) => {
                    let key = String::from_utf8(bytes).map_err(|_| {
                        format!("Invalid {} credential encoding.", credential.label())
                    })?;
                    secrets.insert(credential, key);
                }
                Err(error) if error.code() == NOT_FOUND => {}
                Err(_) => {
                    return Err(format!(
                        "Keychain did not allow access to the {} key.",
                        credential.label()
                    ));
                }
            }
        }
        if !secrets.is_empty() {
            write(&secrets)?;
        }
        delete_entries();
        Ok(secrets)
    }

    fn delete_entries() {
        for credential in Credential::ALL {
            let _ = delete_generic_password(credential.entry(), ENTRY_ACCOUNT);
        }
    }

    /// Replaces the item rather than updating it, so the running build becomes the item's
    /// owner and can read it later without asking.
    pub(super) fn save(secrets: &Secrets, _changed: Credential) -> Result<()> {
        match delete_generic_password(SERVICE, ACCOUNT) {
            Ok(()) => {}
            Err(error) if error.code() == NOT_FOUND => {}
            Err(_) => return Err(SAVE_ERROR.into()),
        }
        delete_entries();
        if secrets.is_empty() {
            return Ok(());
        }
        write(secrets)
    }

    fn write(secrets: &Secrets) -> Result<()> {
        let mut options = ItemAddOptions::new(ItemAddValue::Data {
            class: ItemClass::generic_password(),
            data: CFData::from_buffer(&encode(secrets)),
        });
        options
            .set_service(SERVICE)
            .set_account_name(ACCOUNT)
            .set_label(LABEL)
            .set_comment(names(secrets));
        options.add().map_err(|_| SAVE_ERROR.into())
    }
}

/// Windows Credential Manager never asks the user for approval, so each credential
/// keeps its own entry (one entry could not hold two 2048-character keys).
#[cfg(windows)]
mod platform {
    use std::collections::HashSet;

    use windows_sys::Win32::{Foundation::ERROR_NOT_FOUND, Security::Credentials::*};

    use super::{Credential, ENTRY_ACCOUNT, Secrets};
    use crate::Result;

    pub(super) fn present() -> Result<HashSet<Credential>> {
        Ok(load()?.into_keys().collect())
    }

    pub(super) fn load() -> Result<Secrets> {
        let mut secrets = Secrets::new();
        for credential in Credential::ALL {
            if let Some(key) = get(credential)? {
                secrets.insert(credential, key);
            }
        }
        Ok(secrets)
    }

    pub(super) fn save(secrets: &Secrets, changed: Credential) -> Result<()> {
        set(changed, secrets.get(&changed).map_or("", String::as_str))
    }

    fn set(credential: Credential, key: &str) -> Result<()> {
        let mut target: Vec<u16> = credential.entry().encode_utf16().chain(Some(0)).collect();
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
        let mut user: Vec<u16> = ENTRY_ACCOUNT.encode_utf16().chain(Some(0)).collect();
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

    fn get(credential: Credential) -> Result<Option<String>> {
        let target: Vec<u16> = credential.entry().encode_utf16().chain(Some(0)).collect();
        let mut record = std::ptr::null_mut();
        if unsafe { CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut record) } == 0 {
            return if std::io::Error::last_os_error().raw_os_error() == Some(ERROR_NOT_FOUND as i32)
            {
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
}

#[cfg(not(any(target_os = "macos", windows)))]
mod platform {
    use std::collections::HashSet;

    use super::{Credential, Secrets};
    use crate::Result;

    const UNSUPPORTED: &str = "No supported credential vault on this platform.";

    pub(super) fn present() -> Result<HashSet<Credential>> {
        Err(UNSUPPORTED.into())
    }
    pub(super) fn load() -> Result<Secrets> {
        Err(UNSUPPORTED.into())
    }
    pub(super) fn save(_: &Secrets, _: Credential) -> Result<()> {
        Err(UNSUPPORTED.into())
    }
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

    #[test]
    fn all_keys_round_trip_through_one_vault_item() {
        let mut secrets = Secrets::new();
        secrets.insert(Credential::Typesafe, "mock-typesafe".into());
        secrets.insert(Credential::Anthropic, "mock-anthropic".into());
        assert_eq!(decode(&encode(&secrets)).unwrap(), secrets);
        assert_eq!(names(&secrets), "anthropic,typesafe");
        assert!(decode(&encode(&Secrets::new())).unwrap().is_empty());
        assert!(decode(b"not json").is_err());
        let unknown = decode(br#"{"typesafe":"k","future":"x","anthropic":7}"#).unwrap();
        assert_eq!(unknown.len(), 1);
        assert_eq!(unknown[&Credential::Typesafe], "k");
    }
}
