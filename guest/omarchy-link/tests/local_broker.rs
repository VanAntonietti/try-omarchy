use std::os::unix::fs::PermissionsExt;
use std::{
    fs,
    process::{Command, Stdio},
    thread,
    time::Duration,
};

#[test]
fn owner_can_query_private_broker_without_a_host() {
    let root = std::path::PathBuf::from("/tmp").join(format!("link-test-{}", std::process::id()));
    fs::create_dir(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    fs::create_dir(root.join("omarchy-link")).unwrap();
    fs::set_permissions(root.join("omarchy-link"), fs::Permissions::from_mode(0o700)).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_omarchy-link"))
        .args(["daemon", "--development-fake"])
        .env("OMARCHY_LINK_DEVELOPMENT", "1")
        .env("XDG_RUNTIME_DIR", &root)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let socket = root.join("omarchy-link/socket");
    for _ in 0..100 {
        if socket.exists() {
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }
    let result = Command::new(env!("CARGO_BIN_EXE_omarchy-link"))
        .arg("status")
        .env("XDG_RUNTIME_DIR", &root)
        .output()
        .unwrap();
    let mut call = Command::new(env!("CARGO_BIN_EXE_omarchy-link"))
        .arg("call")
        .env("XDG_RUNTIME_DIR", &root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    use std::io::Write;
    call.stdin
        .take()
        .unwrap()
        .write_all(br#"{"method":"calendar.agenda","date":"2026-04-06","range":"seven-days"}"#)
        .unwrap();
    let output = call.wait_with_output().unwrap();
    let agenda: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    // Unsafe runtime permissions must fail closed rather than expose the endpoint.
    fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();
    let blocked = Command::new(env!("CARGO_BIN_EXE_omarchy-link"))
        .arg("status")
        .env("XDG_RUNTIME_DIR", &root)
        .output()
        .unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    let _ = child.kill();
    let logs = child.wait_with_output().unwrap();
    assert!(logs.stdout.is_empty());
    assert!(logs.stderr.is_empty());
    let blocked: serde_json::Value = serde_json::from_slice(&blocked.stdout).unwrap();
    assert_eq!(blocked["available"], false);
    assert!(blocked.get("adapter").is_none());
    let mode = fs::metadata(&socket).map(|m| m.permissions().mode() & 0o777);
    fs::remove_dir_all(root).unwrap();
    assert!(result.status.success());
    let status: serde_json::Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(status["adapter"], "invented");
    assert_eq!(status["hostAvailable"], false);
    assert_eq!(mode.unwrap(), 0o600);
    assert!(agenda.get("events").is_some(), "{agenda}");
}
