use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use tempfile::TempDir;
struct Service {
    child: Child,
    _dir: TempDir,
    socket: PathBuf,
}
impl Service {
    fn start() -> Self {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("board.sock");
        let child = spawn(dir.path(), &socket);
        let mut s = Self {
            child,
            _dir: dir,
            socket,
        };
        s.wait_ready();
        s
    }
    fn wait_ready(&mut self) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while UnixStream::connect(&self.socket).is_err() {
            assert!(self.child.try_wait().unwrap().is_none(), "service exited");
            assert!(Instant::now() < deadline, "service did not start");
            thread::sleep(Duration::from_millis(20));
        }
    }
    fn restart(&mut self) {
        Command::new("kill")
            .args(["-TERM", &self.child.id().to_string()])
            .status()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while self.child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(20));
        }
        assert!(!self.socket.exists());
        self.child = spawn(self._dir.path(), &self.socket);
        self.wait_ready();
    }
}
impl Drop for Service {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
fn spawn(dir: &Path, socket: &Path) -> Child {
    Command::new(env!("CARGO_BIN_EXE_workboard-service"))
        .arg("--data-dir")
        .arg(dir)
        .arg("--socket")
        .arg(socket)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap()
}
fn rpc(socket: &Path, request_id: &str, method: &str, params: Value) -> Value {
    let mut stream = UnixStream::connect(socket).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    writeln!(
        stream,
        "{}",
        json!({"schema_version":1,"request_id":request_id,"method":method,"params":params})
    )
    .unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}
#[test]
fn actual_socket_claim_race_persistence_and_single_writer_lock() {
    let mut service = Service::start();
    let p = rpc(
        &service.socket,
        "p",
        "project.create",
        json!({"name":"service test"}),
    )["result"]["project_id"]
        .as_str()
        .unwrap()
        .to_string();
    let t = rpc(
        &service.socket,
        "t",
        "task.create",
        json!({"project_id":p,"title":"race"}),
    )["result"]["task_id"]
        .as_str()
        .unwrap()
        .to_string();
    let jobs = (0..8)
        .map(|n| {
            let socket = service.socket.clone();
            let task = t.clone();
            thread::spawn(move || {
                rpc(
                    &socket,
                    &format!("claim-{n}"),
                    "task.claim",
                    json!({"task_id":task,"agent_id":format!("agent-{n}")}),
                )
            })
        })
        .collect::<Vec<_>>();
    let responses = jobs
        .into_iter()
        .map(|j| j.join().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(responses.iter().filter(|r| r["ok"] == true).count(), 1);
    assert_eq!(
        responses
            .iter()
            .filter(|r| r["error"]["code"] == "CLAIM_CONFLICT")
            .count(),
        7
    );
    let mut second = spawn(service._dir.path(), &service._dir.path().join("other.sock"));
    assert!(!second.wait().unwrap().success());
    let before = rpc(&service.socket, "get", "task.get", json!({"task_id":t}));
    service.restart();
    let after = rpc(&service.socket, "get2", "task.get", json!({"task_id":t}));
    assert_eq!(before["result"], after["result"]);
    assert_eq!(
        std::fs::metadata(&service.socket)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(
        std::fs::metadata(service._dir.path())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
}
#[test]
fn malformed_frame_does_not_crash_service() {
    let service = Service::start();
    let mut stream = UnixStream::connect(&service.socket).unwrap();
    stream.write_all(b"{bad json}\n").unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    let error: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(error["error"]["code"], "INVALID_REQUEST");
    assert_eq!(
        rpc(&service.socket, "healthy", "doctor", json!({}))["ok"],
        true
    );
}

#[test]
fn concurrent_different_databases_cannot_replace_each_others_socket() {
    let directory = TempDir::new().unwrap();
    let socket = directory.path().join("shared.sock");
    let mut processes = (0..8)
        .map(|index| spawn(&directory.path().join(format!("db-{index}")), &socket))
        .collect::<Vec<_>>();
    let deadline = Instant::now() + Duration::from_secs(5);
    while UnixStream::connect(&socket).is_err() {
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(20));
    }
    thread::sleep(Duration::from_millis(200));
    let live = processes
        .iter_mut()
        .map(|process| process.try_wait().unwrap().is_none())
        .filter(|live| *live)
        .count();
    let healthy = rpc(&socket, "shared-socket-health", "doctor", json!({}));
    for process in &mut processes {
        let _ = process.kill();
        let _ = process.wait();
    }
    assert_eq!(live, 1, "only one database may own a socket pathname");
    assert_eq!(healthy["ok"], true);
}

#[test]
fn configured_shared_widget_snapshot_updates_after_service_restart() {
    let mut service = Service::start();
    let shared = service._dir.path().join("app-group/widget-snapshot.json");
    assert_eq!(
        rpc(
            &service.socket,
            "configure-widget",
            "widget.configure",
            json!({"snapshot_path":shared})
        )["ok"],
        true
    );
    assert!(shared.exists());
    let project = rpc(
        &service.socket,
        "widget-project",
        "project.create",
        json!({"name":"shared widget"}),
    )["result"]["project_id"]
        .clone();
    service.restart();
    assert_eq!(
        rpc(
            &service.socket,
            "widget-task",
            "task.create",
            json!({"project_id":project,"title":"host closed, service updates widget"})
        )["ok"],
        true
    );
    let snapshot: Value = serde_json::from_slice(&std::fs::read(&shared).unwrap()).unwrap();
    assert_eq!(
        snapshot["tasks"][0]["title"],
        "host closed, service updates widget"
    );
    let saved = std::fs::read(&shared).unwrap();
    assert_eq!(
        rpc(
            &service.socket,
            "unset-widget",
            "widget.configure",
            json!({"snapshot_path":null})
        )["ok"],
        true
    );
    assert_eq!(std::fs::read(&shared).unwrap(), saved);
}
