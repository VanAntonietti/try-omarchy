//! Owner-local IPC plus the guest end of the private host channel. No write
//! execution is available; the channel carries negotiated Calendar Queries.
use omarchy_link::{
    CHANNEL_DEVICE, GuestPeer, GuestSessionState, MacService, PeerMessage, SessionFailure,
    SessionFailureCode, channel_status_value, workspace_identity_from_command_line,
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    env, fs,
    io::{self, Read, Write},
    os::unix::{
        fs::{FileTypeExt, MetadataExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
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
/// The virtio channel and kernel command line are fixed in production; the
/// overrides exist only for the explicit development harness.
fn channel_paths(development: bool) -> (PathBuf, PathBuf) {
    let device = development
        .then(|| env::var_os("OMARCHY_LINK_CHANNEL").map(PathBuf::from))
        .flatten()
        .unwrap_or_else(|| PathBuf::from(CHANNEL_DEVICE));
    let command_line = development
        .then(|| env::var_os("OMARCHY_LINK_CMDLINE").map(PathBuf::from))
        .flatten()
        .unwrap_or_else(|| PathBuf::from("/proc/cmdline"));
    (device, command_line)
}

enum ChannelTransport {
    Device(fs::File),
    Stream(UnixStream),
}

impl ChannelTransport {
    fn try_clone(&self) -> io::Result<Self> {
        match self {
            Self::Device(file) => file.try_clone().map(Self::Device),
            Self::Stream(stream) => stream.try_clone().map(Self::Stream),
        }
    }

    fn open(path: &Path) -> io::Result<Self> {
        if fs::metadata(path)?.file_type().is_socket() {
            let stream = UnixStream::connect(path)?;
            stream.set_write_timeout(Some(Duration::from_millis(200)))?;
            Ok(Self::Stream(stream))
        } else {
            let mut options = fs::OpenOptions::new();
            options.read(true).write(true);
            #[cfg(target_os = "linux")]
            {
                use std::os::unix::fs::OpenOptionsExt;
                // O_NONBLOCK: a stalled host must not stall Owner-local status.
                options.custom_flags(0x800);
            }
            Ok(Self::Device(options.open(path)?))
        }
    }
}

impl Read for ChannelTransport {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Device(file) => file.read(buffer),
            Self::Stream(stream) => stream.read(buffer),
        }
    }
}

impl Write for ChannelTransport {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        match self {
            Self::Device(file) => {
                let deadline = Instant::now() + Duration::from_millis(200);
                loop {
                    match file.write(buffer) {
                        Err(error)
                            if error.kind() == io::ErrorKind::WouldBlock
                                && Instant::now() < deadline =>
                        {
                            thread::sleep(Duration::from_millis(5))
                        }
                        result => return result,
                    }
                }
            }
            Self::Stream(stream) => stream.write(buffer),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Self::Device(file) => file.flush(),
            Self::Stream(stream) => stream.flush(),
        }
    }
}

fn channel_failure(code: &str) -> GuestSessionState {
    GuestSessionState::LinkUnavailable(SessionFailure {
        code: SessionFailureCode::from(code),
        message: "the host Link channel is unavailable".to_owned(),
    })
}

/// Typed in-flight Queries for one host connection; never persisted or replayed.
struct Connection {
    peer: GuestPeer,
    writer: ChannelTransport,
    pending: HashMap<String, mpsc::SyncSender<Value>>,
}
#[derive(Default)]
struct Link {
    state: Option<GuestSessionState>,
    connection: Option<Connection>,
    calendar_revision: u64,
}

fn query(link: &Arc<Mutex<Link>>, request: &Value, development: bool) -> Value {
    if !crate::content_access::allowed(development) {
        return error("session.locked");
    }
    let (sender, receiver) = mpsc::sync_channel(1);
    let id;
    {
        let Ok(mut link) = link.lock() else {
            return error("service.unavailable");
        };
        let Some(connection) = link.connection.as_mut() else {
            return error("service.unavailable");
        };
        let prepared = match request["method"].as_str() {
            Some("calendar.calendars.list") => connection.peer.list_calendars(),
            Some("calendar.events.list") => {
                let Some(start) = request["start"].as_str() else {
                    return error("request.invalid");
                };
                let Some(end) = request["end"].as_str() else {
                    return error("request.invalid");
                };
                let Ok(ids) = serde_json::from_value::<Vec<String>>(request["calendarIds"].clone())
                else {
                    return error("request.invalid");
                };
                connection.peer.list_events(start, end, &ids)
            }
            _ => return error("request.method_unavailable"),
        };
        let Ok((request_id, frame)) = prepared else {
            return error("request.unavailable");
        };
        id = request_id;
        if connection.writer.write_all(&frame).is_err() {
            return error("service.unavailable");
        }
        connection.pending.insert(id.clone(), sender);
    }
    let result = receiver
        .recv_timeout(Duration::from_millis(1000))
        .unwrap_or_else(|_| error("request.timeout"));
    if let Ok(mut link) = link.lock() {
        if let Some(connection) = link.connection.as_mut() {
            if connection.pending.remove(&id).is_some() {
                if let Ok(frame) = connection.peer.cancel(&id) {
                    let _ = connection.writer.write_all(&frame);
                }
            }
        }
    }
    if crate::content_access::allowed(development) {
        result
    } else {
        error("session.locked")
    }
}
fn error(code: &str) -> Value {
    json!({"error":{"code":code,"message":"Calendar content unavailable"}})
}

fn channel_worker(link: Arc<Mutex<Link>>, development: bool) {
    let (device, command_line_path) = channel_paths(development);
    let Some(identity) = fs::read_to_string(command_line_path)
        .ok()
        .and_then(|command_line| workspace_identity_from_command_line(&command_line))
    else {
        return;
    };
    // Unique per attempt and per daemon process: the host remembers every
    // request identifier for the whole Link Session, and a reused hello would
    // escalate a retried handshake into a terminal protocol violation.
    let mut attempt: u64 = 0;
    loop {
        let Ok(mut transport) = ChannelTransport::open(&device) else {
            thread::sleep(Duration::from_secs(5));
            continue;
        };
        attempt += 1;
        let peer = GuestPeer::for_workspace(
            identity.clone(),
            format!("{}-{attempt}", std::process::id()),
        );
        let Ok(writer) = transport.try_clone() else {
            return;
        };
        let mut connection = Connection {
            peer,
            writer,
            pending: HashMap::new(),
        };
        let Ok(hello) = connection.peer.hello_frame() else {
            return;
        };
        if transport.write_all(&hello).is_err() {
            return;
        }
        {
            link.lock().unwrap().connection = Some(connection);
        }
        let mut chunk = [0_u8; 4096];
        let mut terminal = false;
        loop {
            let count = match transport.read(&mut chunk) {
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(10));
                    continue;
                }
                Ok(0) | Err(_) => break,
                Ok(count) => count,
            };
            let mut slot = link.lock().unwrap();
            let Some(connection) = slot.connection.as_mut() else {
                break;
            };
            let received = connection.peer.receive(&chunk[..count]);
            chunk.fill(0);
            let Ok(messages) = received else { break };
            for message in messages {
                match message {
                    PeerMessage::Ready(session) => {
                        slot.state = Some(GuestSessionState::Available(session))
                    }
                    PeerMessage::Unavailable(failure) => {
                        slot.state = Some(GuestSessionState::LinkUnavailable(failure));
                        terminal = true;
                    }
                    PeerMessage::Invalidated(MacService::Calendar) => {
                        slot.calendar_revision = slot.calendar_revision.saturating_add(1)
                    }
                    PeerMessage::Calendars { id, calendars } => {
                        deliver(&mut slot, &id, json!({"calendars":calendars}))
                    }
                    PeerMessage::Events { id, events } => {
                        deliver(&mut slot, &id, json!({"events":events}))
                    }
                    PeerMessage::Failed { id, .. } => {
                        deliver(&mut slot, &id, error("service.unavailable"))
                    }
                    _ => (),
                }
            }
            if terminal {
                break;
            }
        }
        {
            let mut slot = link.lock().unwrap();
            slot.connection = None;
            if !terminal {
                slot.state = Some(channel_failure("channel.closed"));
            }
        }
        if terminal {
            return;
        }
        thread::sleep(Duration::from_secs(2));
    }
}

fn deliver(link: &mut Link, id: &str, value: Value) {
    if let Some(sender) = link
        .connection
        .as_mut()
        .and_then(|connection| connection.pending.remove(id))
    {
        let _ = sender.try_send(value);
    }
}

pub fn daemon(fake: bool) -> io::Result<()> {
    if (fake && env::var("OMARCHY_LINK_DEVELOPMENT").as_deref() != Ok("1"))
        || (!fake && uid() != 1000)
    {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let link = Arc::new(Mutex::new(Link::default()));
    {
        let link = Arc::clone(&link);
        thread::spawn(move || channel_worker(link, fake));
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
    use std::sync::atomic::{AtomicUsize, Ordering};
    let clients = Arc::new(AtomicUsize::new(0));
    for incoming in listener.incoming() {
        let Ok(stream) = incoming else { continue };
        if clients.fetch_add(1, Ordering::SeqCst) >= 8 {
            clients.fetch_sub(1, Ordering::SeqCst);
            continue;
        }
        let link = Arc::clone(&link);
        let clients = Arc::clone(&clients);
        thread::spawn(move || {
            serve_client(stream, &link, fake);
            clients.fetch_sub(1, Ordering::SeqCst);
        });
    }
    Ok(())
}

fn serve_client(mut stream: UnixStream, link: &Arc<Mutex<Link>>, fake: bool) {
    let Ok(request) = receive(&mut stream) else {
        return;
    };
    let response = if request.get("method").and_then(Value::as_str) == Some("status") {
        let mut status = link
            .lock()
            .ok()
            .and_then(|link| link.state.as_ref().map(channel_status_value))
            .unwrap_or_else(unavailable);
        status["adapter"] = json!(if fake { "invented" } else { "host" });
        status["contentAllowed"] = json!(crate::content_access::allowed(fake));
        status["calendarRevision"] =
            json!(link.lock().map(|link| link.calendar_revision).unwrap_or(0));
        status
    } else if matches!(
        request["method"].as_str(),
        Some("calendar.calendars.list" | "calendar.events.list")
    ) {
        query(&link, &request, fake)
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
