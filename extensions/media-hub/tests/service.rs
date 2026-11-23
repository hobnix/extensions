//! The real media-svc program against a tiny local http server that serves the fixtures of tests/fixtures/media-hub, over the service protocol
//! (JSON lines on stdin and stdout). Every app answer is a hand-made fixture: the adapters are UNVERIFIED against a real Jellyfin or Plex.
#![cfg(unix)]
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{channel, Receiver};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use serde_json::{json, Value};

fn fixture(name: &str) -> String {
    std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/media-hub").join(name)).unwrap()
}

fn scratch(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("media-svc-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// A server that answers every GET with the current body and keeps the request heads it saw.
struct Fake {
    port: u16,
    body: Arc<Mutex<String>>,
    heads: Arc<Mutex<Vec<String>>>,
}

fn fake(body: &str) -> Fake {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    let (body, heads) = (Arc::new(Mutex::new(body.to_string())), Arc::new(Mutex::new(Vec::new())));
    let (b, h) = (body.clone(), heads.clone());
    thread::spawn(move || {
        for s in l.incoming().flatten() {
            let mut s = s;
            let mut head = Vec::new();
            let mut byte = [0u8; 1];
            while !head.ends_with(b"\r\n\r\n") && s.read(&mut byte).unwrap_or(0) == 1 {
                head.push(byte[0]);
            }
            h.lock().unwrap().push(String::from_utf8_lossy(&head).into_owned());
            let body = b.lock().unwrap().clone();
            let _ = write!(s, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
        }
    });
    Fake { port, body, heads }
}

struct Svc {
    child: Child,
    stdin: ChildStdin,
    rx: Receiver<Value>,
    seen: Vec<Value>,
}

impl Svc {
    fn start(env: &[(&str, String)]) -> Svc {
        let mut c = Command::new(env!("CARGO_BIN_EXE_media-svc"));
        c.env_clear().stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit());
        for (k, v) in env {
            c.env(k, v);
        }
        let mut child = c.spawn().unwrap();
        let mut stdin = child.stdin.take().unwrap();
        let out = child.stdout.take().unwrap();
        let (tx, rx) = channel();
        thread::spawn(move || {
            for l in BufReader::new(out).lines().map_while(Result::ok) {
                if tx.send(serde_json::from_str(&l).unwrap_or_else(|_| panic!("stdout carries only protocol lines, got: {l}"))).is_err() {
                    break;
                }
            }
        });
        writeln!(stdin, "{}", json!({"v":1,"type":"init","name":"media-hub","lang":"en","subscribe":["pkg.media-hub.imported"],"health_interval":1})).unwrap();
        let mut svc = Svc { child, stdin, rx, seen: Vec::new() };
        svc.wait(|m| m["type"] == "ready");
        svc
    }

    /// The next message that matches, within 10 seconds; every message read is kept in `seen`.
    fn wait(&mut self, want: impl Fn(&Value) -> bool) -> Value {
        loop {
            let m = self.rx.recv_timeout(Duration::from_secs(10)).unwrap_or_else(|_| panic!("no such message; seen: {:?}", self.seen));
            self.seen.push(m.clone());
            if want(&m) {
                return m;
            }
        }
    }

    fn send(&mut self, v: Value) {
        writeln!(self.stdin, "{v}").unwrap();
    }

    fn stop(mut self) -> Vec<Value> {
        self.send(json!({"v":1,"type":"shutdown"}));
        let status = self.child.wait().unwrap();
        assert!(status.success(), "exit {status}");
        while let Ok(m) = self.rx.recv_timeout(Duration::from_millis(200)) {
            self.seen.push(m);
        }
        self.seen
    }
}

fn is_log(text: &'static str) -> impl Fn(&Value) -> bool {
    move |m| m["type"] == "log" && m["text"].as_str().is_some_and(|t| t.contains(text))
}

fn env_for(dir: &Path, listing: &str, creds: &[(&str, &str)], poll: &str) -> Vec<(&'static str, String)> {
    let int = dir.join("listing");
    std::fs::write(&int, listing).unwrap();
    let cdir = dir.join("creds");
    std::fs::create_dir_all(&cdir).unwrap();
    for (n, k) in creds {
        std::fs::write(cdir.join(n), format!("{k}\n")).unwrap();
    }
    vec![
        ("HS_MEDIA_INTEGRATIONS", int.display().to_string()),
        ("CREDENTIALS_DIRECTORY", cdir.display().to_string()),
        ("HS_MEDIA_STATE_DIR", dir.join("state").display().to_string()),
        ("HS_MEDIA_POLL_SECONDS", poll.into()),
        ("HS_MEDIA_MIN_SECONDS", "0".into()),
    ]
}

#[test]
fn polls_jellyfin_with_its_own_key_and_counts_a_finished_playback() {
    let dir = scratch("poll");
    let jf = fake(&fixture("jellyfin-sessions.json"));
    let listing = format!(
        "jellyfin\tmedia\trecipe\thttp://127.0.0.1:{}\tok\t-\tX-Emby-Token\n\
         radarr\tmedia\trecipe\thttp://127.0.0.1:1\tok\tkind=movies\tX-Api-Key\n\
         plex\tmedia\trecipe\thttps://plex.lan:32400\tok\t-\t-\n",
        jf.port
    );
    let mut svc = Svc::start(&env_for(&dir, &listing, &[("integration-media-jellyfin", "JELLY-KEY"), ("integration-media-plex", "PLEX-KEY")], "0.2"));
    let note = svc.wait(is_log("radarr has no adapter"));
    let t = note["text"].as_str().unwrap();
    assert!(t.contains("polling jellyfin") && t.contains("plex is at an https address") && t.contains("TlsUnsupported"), "{t}");
    let snap = svc.wait(|m| m["type"] == "snapshot" && m["data"]["sessions"].as_array().is_some_and(|s| s.len() == 2));
    assert_eq!(snap["topic"], "now-playing");
    assert_eq!(snap["data"]["sessions"][0], json!({"app": "jellyfin", "user": "anna", "title": "Dune"}));
    // the playback ends: counted once, for anna and for carl_smith
    *jf.body.lock().unwrap() = "[]".into();
    let emit = svc.wait(|m| m["type"] == "emit" && m["subject"] == "anna");
    assert_eq!(emit["kind"], "pkg.media-hub.session-completed");
    assert_eq!(emit["payload"], json!({"minutes": 1, "title": "Dune"}));
    let roll = svc.wait(|m| m["type"] == "rollup" && m["user"] == "anna");
    assert_eq!((roll["kind"].as_str(), roll["n"].as_f64(), roll["sum"].as_f64()), (Some("pkg.media-hub.session-completed"), Some(1.0), Some(1.0)));
    svc.wait(|m| m["type"] == "rollup" && m["user"] == "carl_smith");
    svc.wait(|m| m["type"] == "snapshot" && m["data"]["sessions"].as_array().is_some_and(|s| s.is_empty()));
    let seen = svc.stop();
    let heads = jf.heads.lock().unwrap();
    assert!(heads.iter().all(|h| h.starts_with("GET /Sessions HTTP/1.1")), "{heads:?}");
    assert!(heads.iter().all(|h| h.contains("X-Emby-Token: JELLY-KEY\r\n") && !h.contains("PLEX-KEY")), "the key of jellyfin goes to jellyfin only");
    let all = serde_json::to_string(&seen).unwrap();
    assert!(!all.contains("JELLY-KEY") && !all.contains("PLEX-KEY"), "a key is never written to the protocol");
    let w = std::fs::read_to_string(dir.join("state/watched.tsv")).unwrap();
    assert!(w.contains("Dune.mkv\t/media/movies/Dune (2021)"), "{w}");
    let health = seen.iter().rfind(|m| m["type"] == "health").unwrap();
    assert_eq!(health["ok"], true);
}

#[test]
fn polls_plex_in_its_own_header_next_to_jellyfin() {
    let dir = scratch("plex");
    let (jf, px) = (fake("[]"), fake(&fixture("plex-sessions.json")));
    let listing = format!(
        "jellyfin\tmedia\trecipe\thttp://127.0.0.1:{}\tok\t-\t-\nplex\tmedia\trecipe\thttp://127.0.0.1:{}\tok\t-\t-\n",
        jf.port, px.port
    );
    let mut svc = Svc::start(&env_for(&dir, &listing, &[("integration-media-jellyfin", "JK"), ("integration-media-plex", "PK")], "0.2"));
    let snap = svc.wait(|m| m["type"] == "snapshot" && m["data"]["sessions"].as_array().is_some_and(|s| !s.is_empty()));
    assert_eq!(snap["data"]["sessions"][0], json!({"app": "plex", "user": "dora", "title": "Arrival"}));
    svc.stop();
    let (j, p) = (jf.heads.lock().unwrap(), px.heads.lock().unwrap());
    assert!(j[0].starts_with("GET /Sessions ") && j[0].contains("X-Emby-Token: JK\r\n") && !j[0].contains("PK"), "{j:?}");
    assert!(p[0].starts_with("GET /status/sessions ") && p[0].contains("X-Plex-Token: PK\r\n") && !p[0].contains("JK"), "{p:?}");
}

#[test]
fn a_provider_without_a_key_is_not_asked() {
    let dir = scratch("nokey");
    let jf = fake(&fixture("jellyfin-sessions.json"));
    let listing = format!("jellyfin\tmedia\trecipe\thttp://127.0.0.1:{}\tok\t-\t-\n", jf.port);
    let mut svc = Svc::start(&env_for(&dir, &listing, &[], "0.2"));
    svc.wait(is_log("no key handed over for jellyfin"));
    svc.wait(|m| m["type"] == "snapshot");
    svc.stop();
    assert!(jf.heads.lock().unwrap().is_empty(), "no key, no call");
}

#[test]
fn an_imported_event_draws_a_poster_and_is_acknowledged_either_way() {
    let dir = scratch("poster");
    let stub = dir.join("poster-stub.sh");
    std::fs::write(&stub, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$HS_STUB_LOG\"\n[ \"$STUB_FAIL\" != 1 ] || { printf 'status\\trefused\\nreason\\tno such extension\\n'; exit 1; }\nprintf 'status\\tdone\\n'\n").unwrap();
    std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
    let log = dir.join("poster.log");
    let event = |id: u64, payload: Value| json!({"v":1,"type":"event","id":id,"time":1700000000,"source":"pkg","kind":"media-hub.imported","subject":"radarr","level":"info","payload":payload});
    for (fail, name) in [("0", "ok"), ("1", "failing")] {
        let mut env = env_for(&dir, "", &[], "0");
        env.push(("HS_MEDIA_POSTER_CMD", stub.display().to_string()));
        env.push(("HS_STUB_LOG", log.display().to_string()));
        env.push(("STUB_FAIL", fail.into()));
        let _ = std::fs::remove_file(&log);
        let mut svc = Svc::start(&env);
        svc.send(event(1, json!({"title": "A Film", "app": "radarr"})));
        svc.send(event(2, json!({"app": "radarr"})));
        svc.wait(|m| m["type"] == "ack" && m["id"] == 1);
        svc.wait(|m| m["type"] == "ack" && m["id"] == 2);
        let seen = svc.stop();
        let calls = std::fs::read_to_string(&log).unwrap();
        assert_eq!(calls.lines().count(), 1, "{name}: the event without a title draws nothing");
        assert!(calls.contains("--eyebrow New in the library --title A Film --seed "), "{calls}");
        let want = if fail == "1" { "poster not drawn: no such extension" } else { "poster drawn for A Film" };
        assert!(seen.iter().any(|m| is_log(want)(m)), "{name}: {seen:?}");
    }
}
