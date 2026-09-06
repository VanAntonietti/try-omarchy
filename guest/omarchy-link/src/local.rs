//! Owner-local IPC only. No host transport or write execution is available yet.
use serde_json::{Value, json};
use std::{
    env, fs,
    io::{self, Read, Write},
    os::unix::{
        fs::{MetadataExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    time::Duration,
};

unsafe extern "C" {
    fn geteuid() -> u32;
}
fn uid() -> u32 {
    unsafe { geteuid() }
}
fn unavailable() -> Value {
    json!({"available":false,"hostAvailable":false,"reason":"host Link unavailable","protocol":{"major":1,"minor":0}})
}
fn private_directory(path: &Path) -> io::Result<()> {
    let m = fs::symlink_metadata(path)?;
    if !m.is_dir() || m.uid() != uid() || m.mode() & 0o777 != 0o700 {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    Ok(())
}
fn directory() -> io::Result<PathBuf> {
    let root = PathBuf::from(env::var_os("XDG_RUNTIME_DIR").ok_or(io::ErrorKind::NotFound)?);
    if !root.is_absolute() {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    private_directory(&root)?;
    Ok(root.join("omarchy-link"))
}
fn receive(stream: &mut UnixStream) -> io::Result<Value> {
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    let mut header = [0; 4];
    stream.read_exact(&mut header)?;
    let size = u32::from_be_bytes(header) as usize;
    if size == 0 || size > 65536 {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let mut data = vec![0; size];
    stream.read_exact(&mut data)?;
    serde_json::from_slice(&data).map_err(|_| io::ErrorKind::InvalidData.into())
}
fn send(stream: &mut UnixStream, value: &Value) -> io::Result<()> {
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let data = serde_json::to_vec(value)?;
    if data.len() > 65536 {
        return Err(io::ErrorKind::InvalidData.into());
    }
    stream.write_all(&(data.len() as u32).to_be_bytes())?;
    stream.write_all(&data)
}
pub fn client(request: Value) -> io::Result<Value> {
    let dir = directory()?;
    private_directory(&dir)?;
    let mut stream = UnixStream::connect(dir.join("socket"))?;
    send(&mut stream, &request)?;
    receive(&mut stream)
}
pub fn status() -> Value {
    client(json!({"method":"status"})).unwrap_or_else(|_| unavailable())
}
pub fn daemon(fake: bool) -> io::Result<()> {
    if (fake && env::var("OMARCHY_LINK_DEVELOPMENT").as_deref() != Ok("1"))
        || (!fake && uid() != 1000)
    {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let dir = directory()?;
    // Never take over an existing endpoint (including a stale or substituted one).
    use std::os::unix::fs::DirBuilderExt;
    match fs::DirBuilder::new().mode(0o700).create(&dir) {
        Ok(()) => (),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => (),
        Err(error) => return Err(error),
    }
    private_directory(&dir)?;
    let socket = dir.join("socket");
    let listener = UnixListener::bind(&socket)?;
    fs::set_permissions(&socket, fs::Permissions::from_mode(0o600))?;
    for incoming in listener.incoming() {
        let Ok(mut stream) = incoming else { continue };
        let Ok(request) = receive(&mut stream) else {
            continue;
        };
        let response = if request.get("method").and_then(Value::as_str) == Some("status") {
            let mut status = unavailable();
            status["adapter"] = json!(if fake { "invented" } else { "unavailable" });
            status
        } else if fake && request["method"] == "calendar.agenda" {
            use omarchy_link::{AgendaRange, DevelopmentAgendaBroker, InventedCalendarHostAdapter};
            use std::str::FromStr;
            let result = request["date"]
                .as_str()
                .zip(request["range"].as_str())
                .and_then(|(date, range)| {
                    AgendaRange::from_str(range).ok().and_then(|range| {
                        DevelopmentAgendaBroker::new(InventedCalendarHostAdapter)
                            .agenda(date, range, request["calendar"].as_str())
                            .ok()
                    })
                });
            match result {
                Some(snapshot) => serde_json::to_value(snapshot).unwrap_or(Value::Null),
                None => {
                    json!({"error":{"code":"request.invalid","message":"invalid agenda query"}})
                }
            }
        } else {
            json!({"error":{"code":"service.unavailable","message":"host Link unavailable"}})
        };
        let _ = send(&mut stream, &response);
    }
    Ok(())
}
