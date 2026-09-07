//! One broker-owned visible review process. No client-supplied approval route.
use serde_json::Value;
use std::{
    env,
    io::Write,
    os::unix::process::CommandExt,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

struct ReviewProcess(Child);
impl Drop for ReviewProcess {
    fn drop(&mut self) {
        unsafe extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
        }
        // The private renderer and all descendants share this process group.
        unsafe {
            kill(-(self.0.id() as i32), 15);
        }
        let deadline = Instant::now() + Duration::from_millis(300);
        while matches!(self.0.try_wait(), Ok(None)) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        unsafe {
            kill(-(self.0.id() as i32), 9);
        }
        let _ = self.0.wait();
    }
}

pub fn approve(proposal: &Value, development_fixture: bool, usable: impl Fn() -> bool) -> bool {
    let fixture = development_fixture
        .then(|| env::var_os("OMARCHY_LINK_REVIEW_FIXTURE"))
        .flatten();
    if !usable() || (fixture.is_none() && env::var_os("WAYLAND_DISPLAY").is_none()) {
        return false;
    }
    let mut command = if let Some(path) = fixture {
        Command::new(path)
    } else {
        let mut command = Command::new("/usr/bin/python3");
        command.args([
            "-B",
            "/usr/share/try-omarchy/omarchy-link-calendar/review.py",
        ]);
        command
    };
    let Ok(child) = command
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
    else {
        return false;
    };
    let mut child = ReviewProcess(child);
    let Ok(body) = serde_json::to_vec(proposal) else {
        return false;
    };
    if child
        .0
        .stdin
        .take()
        .is_none_or(|mut input| input.write_all(&body).is_err())
    {
        return false;
    }
    let deadline = Instant::now() + Duration::from_secs(110);
    while usable() && Instant::now() < deadline {
        match child.0.try_wait() {
            Ok(Some(status)) => return status.success() && usable(),
            Ok(None) => thread::sleep(Duration::from_millis(50)),
            Err(_) => return false,
        }
    }
    false
}
