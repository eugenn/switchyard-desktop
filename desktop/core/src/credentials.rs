use std::sync::Mutex;

use crate::Result;

const SERVICE: &str = "dev.switchyard.desktop.preview.typesafe";
const ACCOUNT: &str = "api-key";

pub struct CredentialVault {
    memory: Option<Mutex<Option<String>>>,
}

impl CredentialVault {
    pub fn isolated() -> Self {
        Self {
            memory: Some(Mutex::new(None)),
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
        if key.len() > 2048 || key.bytes().any(|byte| !byte.is_ascii_graphic()) {
            return Err(
                "Enter an API key up to 2048 characters without spaces or control characters."
                    .into(),
            );
        }
        if let Some(memory) = &self.memory {
            *memory
                .lock()
                .map_err(|_| "Could not access isolated credentials.")? = if key.is_empty() {
                None
            } else {
                Some(key.into())
            };
            return Ok(());
        }
        platform_set(key)
    }

    pub fn has_typesafe_key(&self) -> Result<bool> {
        self.typesafe_key().map(|key| key.is_some())
    }

    pub(crate) fn typesafe_key(&self) -> Result<Option<String>> {
        if let Some(memory) = &self.memory {
            return memory
                .lock()
                .map(|key| key.clone())
                .map_err(|_| "Could not access isolated credentials.".into());
        }
        platform_get()
    }
}

#[cfg(target_os = "macos")]
fn platform_set(key: &str) -> Result<()> {
    use security_framework::passwords::{delete_generic_password, set_generic_password};
    let result = if key.is_empty() {
        delete_generic_password(SERVICE, ACCOUNT)
    } else {
        set_generic_password(SERVICE, ACCOUNT, key.as_bytes())
    };
    match result {
        Ok(()) => Ok(()),
        Err(error) if key.is_empty() && error.code() == -25300 => Ok(()),
        Err(_) => Err("Keychain did not save the TypeSafe key. Check access permissions.".into()),
    }
}

#[cfg(target_os = "macos")]
fn platform_get() -> Result<Option<String>> {
    match security_framework::passwords::get_generic_password(SERVICE, ACCOUNT) {
        Ok(bytes) => String::from_utf8(bytes)
            .map(Some)
            .map_err(|_| "Invalid TypeSafe credential encoding.".into()),
        Err(error) if error.code() == -25300 => Ok(None),
        Err(_) => Err("Keychain did not allow access to the TypeSafe key.".into()),
    }
}

#[cfg(windows)]
fn platform_set(key: &str) -> Result<()> {
    use windows_sys::Win32::{Foundation::ERROR_NOT_FOUND, Security::Credentials::*};
    let mut target: Vec<u16> = SERVICE.encode_utf16().chain(Some(0)).collect();
    if key.is_empty() {
        if unsafe { CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0) } == 0
            && std::io::Error::last_os_error().raw_os_error() != Some(ERROR_NOT_FOUND as i32)
        {
            return Err("Credential Manager did not delete the TypeSafe key.".into());
        }
        return Ok(());
    }
    let mut user: Vec<u16> = ACCOUNT.encode_utf16().chain(Some(0)).collect();
    let mut bytes = key.as_bytes().to_vec();
    let credential = CREDENTIALW {
        Type: CRED_TYPE_GENERIC,
        TargetName: target.as_mut_ptr(),
        CredentialBlobSize: bytes.len() as u32,
        CredentialBlob: bytes.as_mut_ptr(),
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        UserName: user.as_mut_ptr(),
        ..Default::default()
    };
    if unsafe { CredWriteW(&credential, 0) } == 0 {
        return Err("Credential Manager did not save the TypeSafe key.".into());
    }
    Ok(())
}

#[cfg(windows)]
fn platform_get() -> Result<Option<String>> {
    use windows_sys::Win32::{Foundation::ERROR_NOT_FOUND, Security::Credentials::*};
    let target: Vec<u16> = SERVICE.encode_utf16().chain(Some(0)).collect();
    let mut credential = std::ptr::null_mut();
    if unsafe { CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) } == 0 {
        return if std::io::Error::last_os_error().raw_os_error() == Some(ERROR_NOT_FOUND as i32) {
            Ok(None)
        } else {
            Err("Credential Manager did not allow access to the TypeSafe key.".into())
        };
    }
    let result = unsafe {
        if (*credential).CredentialBlobSize == 0
            || (*credential).CredentialBlobSize > 2048
            || (*credential).CredentialBlob.is_null()
        {
            Err("Invalid TypeSafe credential size.".into())
        } else {
            String::from_utf8(
                std::slice::from_raw_parts(
                    (*credential).CredentialBlob,
                    (*credential).CredentialBlobSize as usize,
                )
                .to_vec(),
            )
            .map(Some)
            .map_err(|_| "Invalid TypeSafe credential encoding.".into())
        }
    };
    unsafe {
        CredFree(credential.cast());
    }
    result
}

#[cfg(not(any(target_os = "macos", windows)))]
fn platform_set(_: &str) -> Result<()> {
    Err("No supported credential vault on this platform.".into())
}
#[cfg(not(any(target_os = "macos", windows)))]
fn platform_get() -> Result<Option<String>> {
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
}
