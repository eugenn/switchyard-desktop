use std::{
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

use crate::Result;

pub(crate) struct OwnedProcess {
    child: Child,
    output_reader: Option<std::thread::JoinHandle<()>>,
    #[cfg(windows)]
    job: windows_sys::Win32::Foundation::HANDLE,
}

#[cfg(windows)]
unsafe impl Send for OwnedProcess {}

impl OwnedProcess {
    pub(crate) fn spawn(command: &mut Command) -> Result<Self> {
        Self::launch(command, false, false)
    }

    pub(crate) fn capture(
        command: &mut Command,
    ) -> Result<(Self, std::sync::Arc<std::sync::Mutex<Vec<u8>>>)> {
        Self::capture_limited(command, 16_384)
    }

    pub(crate) fn capture_with_input(
        command: &mut Command,
        limit: usize,
    ) -> Result<(Self, std::sync::Arc<std::sync::Mutex<Vec<u8>>>)> {
        Self::capture_output(command, limit, true)
    }

    pub(crate) fn capture_limited(
        command: &mut Command,
        limit: usize,
    ) -> Result<(Self, std::sync::Arc<std::sync::Mutex<Vec<u8>>>)> {
        Self::capture_output(command, limit, false)
    }

    fn capture_output(
        command: &mut Command,
        limit: usize,
        input: bool,
    ) -> Result<(Self, std::sync::Arc<std::sync::Mutex<Vec<u8>>>)> {
        use std::io::Read;
        let mut process = Self::launch(command, true, input)?;
        let mut stdout = process
            .child
            .stdout
            .take()
            .ok_or("No sign-in output pipe")?;
        let output = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let destination = output.clone();
        process.output_reader = Some(std::thread::spawn(move || {
            let mut chunk = [0; 1024];
            while let Ok(count) = stdout.read(&mut chunk) {
                if count == 0 {
                    break;
                }
                if let Ok(mut bytes) = destination.lock() {
                    let remaining = limit.saturating_sub(bytes.len());
                    bytes.extend_from_slice(&chunk[..count.min(remaining)]);
                }
            }
        }));
        Ok((process, output))
    }

    fn launch(command: &mut Command, capture: bool, input: bool) -> Result<Self> {
        command
            .stdin(if input { Stdio::piped() } else { Stdio::null() })
            .stdout(if capture {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stderr(Stdio::null());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000 | 0x00000200 | 0x00000004);
        }
        let child = command
            .spawn()
            .map_err(|error| format!("Could not launch bundled process: {error}"))?;
        #[cfg(windows)]
        {
            use std::{
                mem::{size_of, zeroed},
                os::windows::io::AsRawHandle,
                ptr::null,
            };
            use windows_sys::Win32::{Foundation::CloseHandle, System::JobObjects::*};
            let mut child = child;
            let job = unsafe { CreateJobObjectW(null(), null()) };
            if job.is_null() {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "Could not create process job: {}",
                    std::io::Error::last_os_error()
                ));
            }
            let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { zeroed() };
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let configured = unsafe {
                SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    &limits as *const _ as _,
                    size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                ) != 0
                    && AssignProcessToJobObject(job, child.as_raw_handle() as _) != 0
            };
            if !configured {
                let error = std::io::Error::last_os_error();
                let _ = child.kill();
                let _ = child.wait();
                unsafe {
                    CloseHandle(job);
                }
                return Err(format!("Could not contain bundled process: {error}"));
            }
            if let Err(error) = resume_owned_process(child.id()) {
                let _ = child.kill();
                let _ = child.wait();
                unsafe {
                    CloseHandle(job);
                }
                return Err(error);
            }
            Ok(Self {
                child,
                job,
                output_reader: None,
            })
        }
        #[cfg(not(windows))]
        Ok(Self {
            child,
            output_reader: None,
        })
    }

    pub(crate) async fn finish_output(&mut self) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(2);
        while self
            .output_reader
            .as_ref()
            .is_some_and(|reader| !reader.is_finished())
        {
            if Instant::now() >= deadline {
                return Err("Command output remained open after the process exited.".into());
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        if let Some(reader) = self.output_reader.take() {
            reader
                .join()
                .map_err(|_| "Could not finish command output.".to_string())?;
        }
        Ok(())
    }

    pub(crate) fn write_input(&mut self, bytes: &[u8]) -> Result<()> {
        use std::io::Write;
        self.child
            .stdin
            .as_mut()
            .ok_or("No command input pipe.")?
            .write_all(bytes)
            .map_err(|_| "Could not send model discovery request.".into())
    }

    pub(crate) fn exit_success(&mut self) -> Result<Option<bool>> {
        self.child
            .try_wait()
            .map(|status| status.map(|status| status.success()))
            .map_err(|error| error.to_string())
    }

    pub(crate) fn is_running(&mut self) -> Result<bool> {
        self.child
            .try_wait()
            .map(|status| status.is_none())
            .map_err(|error| error.to_string())
    }

    pub(crate) async fn wait_success(&mut self, timeout: Duration) -> Result<()> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(status) = self.child.try_wait().map_err(|error| error.to_string())? {
                return if status.success() {
                    Ok(())
                } else {
                    Err(format!("Bundled process exited with {status}"))
                };
            }
            if Instant::now() >= deadline {
                return Err("Bundled process timed out.".into());
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    pub(crate) fn stop(&mut self) {
        if matches!(self.child.try_wait(), Ok(Some(_))) {
            return;
        }
        #[cfg(unix)]
        unsafe {
            libc::kill(-(self.child.id() as i32), libc::SIGTERM);
        }
        #[cfg(windows)]
        unsafe {
            windows_sys::Win32::System::JobObjects::TerminateJobObject(self.job, 1);
        }
        let deadline = Instant::now() + Duration::from_millis(700);
        while matches!(self.child.try_wait(), Ok(None)) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        #[cfg(unix)]
        unsafe {
            libc::kill(-(self.child.id() as i32), libc::SIGKILL);
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(windows)]
fn resume_owned_process(process_id: u32) -> Result<()> {
    use std::mem::{size_of, zeroed};
    use windows_sys::Win32::{
        Foundation::{CloseHandle, INVALID_HANDLE_VALUE},
        System::{
            Diagnostics::ToolHelp::{
                CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First,
                Thread32Next,
            },
            Threading::{OpenThread, ResumeThread, THREAD_SUSPEND_RESUME},
        },
    };
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err("Could not inspect the suspended child thread.".into());
    }
    let mut entry: THREADENTRY32 = unsafe { zeroed() };
    entry.dwSize = size_of::<THREADENTRY32>() as u32;
    let mut available = unsafe { Thread32First(snapshot, &mut entry) } != 0;
    let mut result = Err("Could not find the suspended child thread.".into());
    while available {
        if entry.th32OwnerProcessID == process_id {
            let thread = unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) };
            if !thread.is_null() {
                let resumed = unsafe { ResumeThread(thread) };
                unsafe {
                    CloseHandle(thread);
                }
                result = if resumed == u32::MAX {
                    Err("Could not resume the contained child process.".into())
                } else {
                    Ok(())
                };
            }
            break;
        }
        available = unsafe { Thread32Next(snapshot, &mut entry) } != 0;
    }
    unsafe {
        CloseHandle(snapshot);
    }
    result
}

impl Drop for OwnedProcess {
    fn drop(&mut self) {
        self.stop();
        #[cfg(windows)]
        unsafe {
            windows_sys::Win32::Foundation::CloseHandle(self.job);
        }
    }
}

pub(crate) fn python_command(
    runtime: &crate::RuntimeLayout,
    locations: &crate::UserDataLocations,
) -> Command {
    let mut command = Command::new(runtime.python());
    command.arg("-I").arg(runtime.launcher());
    for key in [
        "PYTHONPATH",
        "PYTHONHOME",
        "LITELLM_MASTER_KEY",
        "LITELLM_CONFIG",
        "DATABASE_URL",
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "GEMINI_API_KEY",
    ] {
        command.env_remove(key);
    }
    command.env("PYTHONDONTWRITEBYTECODE", "1");
    command.env("PYTHONUNBUFFERED", "1");
    command.current_dir(locations.root());
    command.env("CHATGPT_TOKEN_DIR", locations.auth_directory());
    command.env_remove("CHATGPT_AUTH_FILE");
    command.env_remove("CHATGPT_API_BASE");
    command.env_remove("OPENAI_CHATGPT_API_BASE");
    command
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn dropping_owner_terminates_only_its_child() {
        let mut command = Command::new("/bin/sleep");
        command.arg("30");
        let process = OwnedProcess::spawn(&mut command).unwrap();
        let process_id = process.child.id() as i32;
        assert_eq!(unsafe { libc::kill(process_id, 0) }, 0);
        drop(process);
        assert_ne!(unsafe { libc::kill(process_id, 0) }, 0);
    }
}
