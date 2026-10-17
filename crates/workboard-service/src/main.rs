use fs2::FileExt;
use std::{
    fs::{self, OpenOptions},
    io::{BufRead, BufReader, Write},
    os::unix::{
        fs::{FileTypeExt, OpenOptionsExt},
        net::{UnixListener, UnixStream},
    },
    path::PathBuf,
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};
use workboard_core::{default_data_dir, private_permissions, ApiError, Board, Request, Response};
const MAX_REQUEST_BYTES: usize = 1024 * 1024;
/// Requests or accept-loop pauses longer than this are logged with their phases.
const SLOW: Duration = Duration::from_secs(2);

fn stamp() -> String {
    chrono::Local::now()
        .format("%Y-%m-%d %H:%M:%S%.3f")
        .to_string()
}

fn main() {
    if let Err(e) = run() {
        eprintln!("workboard-service: {e}");
        std::process::exit(1);
    }
}
fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut data_dir = default_data_dir();
    let mut socket = std::env::var_os("WORKBOARD_SOCKET").map(PathBuf::from);
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--data-dir" => data_dir = args.next().ok_or("--data-dir requires a path")?.into(),
            "--socket" => socket = Some(args.next().ok_or("--socket requires a path")?.into()),
            "--help" | "-h" => {
                println!("workboard-service [--data-dir PATH] [--socket PATH]\nEnvironment: WORKBOARD_DATA_DIR, WORKBOARD_SOCKET, WORKBOARD_WIDGET_SNAPSHOT");
                return Ok(());
            }
            "--version" | "-V" => {
                println!("workboard-service {}", env!("CARGO_PKG_VERSION"));
                return Ok(());
            }
            _ => return Err(format!("Unknown argument: {arg}").into()),
        }
    }
    let socket = socket.unwrap_or_else(|| data_dir.join("workboard.sock"));
    // Darwin sockaddr_un.sun_path holds 104 bytes including the terminator.
    if socket.as_os_str().as_encoded_bytes().len() > 103 {
        return Err("The socket path is too long. Use --socket to specify a shorter path".into());
    }
    fs::create_dir_all(&data_dir)?;
    private_permissions(&data_dir, 0o700)?;
    let lock = OpenOptions::new()
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .truncate(false)
        .read(true)
        .write(true)
        .open(data_dir.join("service.lock"))?;
    private_permissions(&data_dir.join("service.lock"), 0o600)?;
    lock.try_lock_exclusive()
        .map_err(|_| "A service is already running for this data directory")?;
    if let Some(parent) = socket.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut socket_lock_path = socket.as_os_str().to_os_string();
    socket_lock_path.push(".lock");
    let socket_lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(PathBuf::from(socket_lock_path))?;
    socket_lock
        .try_lock_exclusive()
        .map_err(|_| "A service is already using this socket")?;
    // The per-socket lock also serializes stale-socket cleanup across different data directories.
    // Do not unlink an active listener, including another data directory using the same socket.
    if UnixStream::connect(&socket).is_ok() {
        return Err("A service is already using this socket".into());
    }
    if socket.exists() {
        if !fs::symlink_metadata(&socket)?.file_type().is_socket() {
            return Err("The socket path contains a regular file or symbolic link".into());
        }
        fs::remove_file(&socket)?;
    }
    if let Some(parent) = socket.parent() {
        fs::create_dir_all(parent)?;
    }
    let reloader = WidgetReloader::start();
    let mut opened = Board::open(&data_dir)?;
    reconcile_executor_registry(&mut opened, &data_dir)?;
    if opened.take_widget_change() {
        reloader.request();
    }
    let board = Arc::new(Mutex::new(opened));
    let listener = UnixListener::bind(&socket)?;
    private_permissions(&socket, 0o600)?;
    listener.set_nonblocking(true)?;
    let running = Arc::new(AtomicBool::new(true));
    let alive = Arc::clone(&running);
    ctrlc::set_handler(move || alive.store(false, Ordering::SeqCst))?;
    let automation = start_automation_worker(
        Arc::clone(&board),
        Arc::clone(&running),
        data_dir.clone(),
        socket.clone(),
    );
    eprintln!("workboard-service ready: {}", socket.display());
    let mut clients = Vec::new();
    while running.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, _)) => {
                let accepted = Instant::now();
                // Limit open clients; a stalled reader cannot hold the database mutex.
                clients.retain(|client: &thread::JoinHandle<()>| !client.is_finished());
                if clients.len() >= 32 {
                    drop(stream);
                    continue;
                }
                let board = Arc::clone(&board);
                let reloader = reloader.clone();
                clients.push(thread::spawn(move || {
                    if let Err(e) = client(stream, board, reloader, accepted) {
                        eprintln!("client: {e}");
                    }
                }));
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                // Instant excludes system sleep, so a long pause here means the process was not scheduled.
                let paused = Instant::now();
                thread::sleep(Duration::from_millis(20));
                let late = paused.elapsed();
                if late > SLOW {
                    eprintln!(
                        "{} Connection accept loop woke {:.1} seconds late",
                        stamp(),
                        late.as_secs_f64()
                    );
                }
            }
            Err(e) => return Err(e.into()),
        }
    }
    drop(listener);
    let _ = fs::remove_file(&socket);
    // Existing clients have a short read deadline; wait for in-flight transactions to finish.
    for client in clients {
        let _ = client.join();
    }
    let _ = automation.join();
    let _ = FileExt::unlock(&lock);
    Ok(())
}

fn reconcile_executor_registry(
    board: &mut Board,
    data_dir: &std::path::Path,
) -> Result<(), Box<dyn std::error::Error>> {
    let directory = data_dir.join("plugins");
    if !directory.is_dir() {
        board.reconcile_automation_executors(&serde_json::json!({}))?;
        return Ok(());
    }
    let reconciled = (|| -> Result<(), Box<dyn std::error::Error>> {
        // Plugin edits hold the same lock, so a concurrent disable cannot escape startup fencing.
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(directory.join("registry.lock"))?;
        let started = Instant::now();
        loop {
            match lock.try_lock_exclusive() {
                Ok(()) => break,
                Err(error)
                    if error.kind() == std::io::ErrorKind::WouldBlock
                        && started.elapsed() < Duration::from_secs(1) =>
                {
                    thread::sleep(Duration::from_millis(20))
                }
                Err(error) => return Err(error.into()),
            }
        }
        let path = directory.join("registry.json");
        let registry = if path.is_file() {
            serde_json::from_slice(&fs::read(path)?)?
        } else {
            serde_json::json!({})
        };
        board.reconcile_automation_executors(&registry)?;
        Ok(())
    })();
    if let Err(error) = reconciled {
        eprintln!("Optional executor registry unavailable; workflow execution is blocked: {error}");
        board.reconcile_automation_executors(&serde_json::json!({}))?;
    }
    Ok(())
}

/// Only the generic host runs here. Provider discovery and calls stay behind enabled plugins.
fn start_automation_worker(
    board: Arc<Mutex<Board>>,
    running: Arc<AtomicBool>,
    data_dir: PathBuf,
    socket: PathBuf,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        use std::os::unix::process::CommandExt;
        let executable = std::env::var_os("WORKBOARD_CLI_BIN")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::current_exe()
                    .ok()
                    .and_then(|path| path.parent().map(|parent| parent.join("workboard")))
            });
        while running.load(Ordering::SeqCst) {
            let pending = board
                .lock()
                .map(|board| board.has_automation_work())
                .unwrap_or(false);
            if pending {
                if let Some(executable) = &executable {
                    match Command::new(executable)
                        .arg("automation")
                        .arg("worker")
                        .arg("--data-dir")
                        .arg(&data_dir)
                        .arg("--socket")
                        .arg(&socket)
                        .arg("--json")
                        .process_group(0)
                        .stdin(Stdio::null())
                        .stdout(Stdio::null())
                        .stderr(Stdio::inherit())
                        .spawn()
                    {
                        Ok(mut child) => {
                            let started = Instant::now();
                            loop {
                                if child.try_wait().ok().flatten().is_some() {
                                    break;
                                }
                                if !running.load(Ordering::SeqCst)
                                    || started.elapsed() > Duration::from_secs(40)
                                {
                                    unsafe {
                                        libc::kill(-(child.id() as i32), libc::SIGTERM);
                                    }
                                    thread::sleep(Duration::from_millis(200));
                                    let _ = child.kill();
                                    let _ = child.wait();
                                    break;
                                }
                                thread::sleep(Duration::from_millis(100));
                            }
                        }
                        Err(error) => eprintln!("automation worker: {error}"),
                    }
                }
            }
            for _ in 0..10 {
                if !running.load(Ordering::SeqCst) {
                    break;
                }
                thread::sleep(Duration::from_millis(100));
            }
        }
    })
}
fn client(
    mut stream: UnixStream,
    board: Arc<Mutex<Board>>,
    reloader: WidgetReloader,
    accepted: Instant,
) -> Result<(), Box<dyn std::error::Error>> {
    // Darwin can inherit O_NONBLOCK from the listening socket. Framed requests
    // may arrive in several reads; the configured deadlines require blocking I/O.
    stream.set_nonblocking(false)?;
    validate_peer(&stream)?;
    stream.set_read_timeout(Some(Duration::from_secs(3)))?;
    stream.set_write_timeout(Some(Duration::from_secs(10)))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut first = true;
    loop {
        let mut bytes = Vec::new();
        // read_until alone can allocate without bound; take() limits each newline frame.
        let n = {
            use std::io::Read;
            reader
                .by_ref()
                .take((MAX_REQUEST_BYTES + 1) as u64)
                .read_until(b'\n', &mut bytes)?
        };
        if n == 0 {
            break;
        }
        // Later frames may arrive after an idle gap, so only the first read counts toward a slow request.
        let read = if first {
            accepted.elapsed()
        } else {
            Duration::ZERO
        };
        first = false;
        let mut method = String::new();
        let (mut waited, mut handled) = (Duration::ZERO, Duration::ZERO);
        let response = if bytes.len() > MAX_REQUEST_BYTES {
            Response::failure(
                "",
                ApiError::new("REQUEST_TOO_LARGE", "Requests must not exceed 1 MiB"),
            )
        } else if bytes.last() != Some(&b'\n') {
            Response::failure(
                "",
                ApiError::new("INVALID_REQUEST", "Requests must end with a newline"),
            )
        } else {
            match serde_json::from_slice::<Request>(&bytes) {
                Ok(request) => {
                    method = request.method.clone();
                    let asked = Instant::now();
                    let mut board = board.lock().map_err(|_| "Could not lock service state")?;
                    waited = asked.elapsed();
                    let begun = Instant::now();
                    let response = board.dispatch(request);
                    if board.take_widget_change() {
                        reloader.request();
                    }
                    handled = begun.elapsed();
                    response
                }
                Err(e) => Response::failure("", ApiError::new("INVALID_REQUEST", e.to_string())),
            }
        };
        // Logged before the reply, which fails with a broken pipe once the client stops waiting.
        if read + waited + handled > SLOW {
            eprintln!(
                "{} Slow request {method}: arrival after connect {} ms, lock wait {} ms, processing {} ms",
                stamp(),
                read.as_millis(),
                waited.as_millis(),
                handled.as_millis()
            );
        }
        let replying = Instant::now();
        stream.write_all(&serde_json::to_vec(&response)?)?;
        stream.write_all(b"\n")?;
        stream.flush()?;
        if replying.elapsed() > SLOW {
            eprintln!(
                "{} Slow response write {method}: {} ms",
                stamp(),
                replying.elapsed().as_millis()
            );
        }
        if bytes.len() > MAX_REQUEST_BYTES {
            break;
        }
    }
    Ok(())
}

/// WidgetKit reloads desktop widgets only on requests from the app that contains them. After the
/// shared snapshot changes, the service runs the bundled app executable in its UI-less
/// `--reload-widgets` mode. Changes that arrive during a run collapse into one more run.
#[derive(Clone)]
struct WidgetReloader(Option<mpsc::Sender<()>>);
impl WidgetReloader {
    fn start() -> Self {
        let Some(app) = bundled_app_executable() else {
            return Self(None);
        };
        let (sender, requests) = mpsc::channel::<()>();
        thread::spawn(move || {
            while requests.recv().is_ok() {
                while requests.try_recv().is_ok() {}
                let child = Command::new(&app)
                    .arg("--reload-widgets")
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn();
                let mut child = match child {
                    Ok(child) => child,
                    Err(e) => {
                        eprintln!("widget reload: {e}");
                        continue;
                    }
                };
                let deadline = Instant::now() + Duration::from_secs(10);
                while matches!(child.try_wait(), Ok(None)) && Instant::now() < deadline {
                    thread::sleep(Duration::from_millis(50));
                }
                if matches!(child.try_wait(), Ok(None)) {
                    let _ = child.kill();
                    let _ = child.wait();
                }
            }
        });
        Self(Some(sender))
    }
    fn request(&self) {
        if let Some(sender) = &self.0 {
            let _ = sender.send(());
        }
    }
}

/// `…/Agent Workboard.app/Contents/Helpers/workboard-service` → `…/Contents/MacOS/WorkboardApp`.
/// Development builds outside an app bundle have no widgets to reload.
fn bundled_app_executable() -> Option<PathBuf> {
    let service = std::env::current_exe().ok()?.canonicalize().ok()?;
    let contents = service.parent()?.parent()?;
    let app = contents.join("MacOS/WorkboardApp");
    (contents.file_name()? == "Contents" && app.is_file()).then_some(app)
}

fn validate_peer(stream: &UnixStream) -> std::io::Result<()> {
    use std::os::fd::AsRawFd;
    #[cfg(target_os = "macos")]
    let peer_uid = unsafe {
        let mut uid: libc::uid_t = 0;
        let mut gid: libc::gid_t = 0;
        if libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) != 0 {
            return Err(std::io::Error::last_os_error());
        }
        uid
    };
    #[cfg(target_os = "linux")]
    let peer_uid = unsafe {
        let mut credentials: libc::ucred = std::mem::zeroed();
        let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        if libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut credentials as *mut _ as *mut libc::c_void,
            &mut length,
        ) != 0
        {
            return Err(std::io::Error::last_os_error());
        }
        credentials.uid
    };
    if peer_uid != unsafe { libc::geteuid() } {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "Only the same user can connect to the service",
        ));
    }
    Ok(())
}
