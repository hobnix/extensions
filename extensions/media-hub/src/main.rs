// The service of the media hub (hobnix/core#928, ported to Rust in hobnix/extensions#27; docs/extensions-sdk.md "Write it in Rust", ADR 0011).
// One process that stays:
//   - the poller: every HS_MEDIA_POLL_SECONDS (default 30; 0 = off) it asks the media apps who plays what (adapter.rs, one adapter per app), counts a
//     finished playback (a `rollup` and an `emit` of session-completed, both through the service protocol) and publishes who plays now as the snapshot
//     topic now-playing (one document, overwritten).
// The poster of an `imported` event is not drawn here: the package `posters` handles pkg.media-hub.imported itself (its service poster-svc.py), so this
// service never runs a host command for it.
// The protocol has no timer, so the service is the timer (a worker thread). It starts no change on storage: that is a suggestion the person confirms.
// Keys: only through `credential_for("media", <provider>)` ($CREDENTIALS_DIRECTORY/integration-media-<provider>), never argv or environment, never
// logged, and a key goes only to the address of the provider it belongs to. Plain http only: an https address is named in the log, not polled.
// Test knobs: HS_MEDIA_INTEGRATIONS (a file with the rows of the integration listing instead of `hs sys pkg integrations media`),
// HS_MEDIA_STATE_DIR,
// HS_MEDIA_POLL_SECONDS, HS_MEDIA_MIN_SECONDS (the shortest playback that counts, default 60).
mod adapter;
mod poll;

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::process::{Command, ExitCode, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use hobnix_ext_sdk::http::{Client, HttpError};
use hobnix_ext_sdk::integrations;
use hobnix_ext_sdk::service::{credential_for, run, Ctx, Health, Init, Service};
use hobnix_ext_sdk::{Event, LogLevel};
use serde_json::{json, Map, Value};

use poll::{clean, parse_apps, user_name, App, Finished, Playing, Poller};

const SESSION_KIND: &str = "pkg.media-hub.session-completed"; // declared in package.toml with retention = "metric": the rollup kind
const HTTP_TIMEOUT: Duration = Duration::from_secs(5);

fn env_f64(name: &str, default: f64) -> f64 {
    std::env::var(name).ok().and_then(|v| v.trim().parse().ok()).filter(|v: &f64| v.is_finite() && *v >= 0.0).unwrap_or(default)
}

fn now_secs() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

fn log(ctx: &Ctx, level: LogLevel, text: &str) {
    let _ = ctx.log(level, text);
}

/// The rows of the integration listing.
fn listing() -> Result<String, String> {
    if let Some(f) = std::env::var_os("HS_MEDIA_INTEGRATIONS") {
        return std::fs::read_to_string(&f).map_err(|e| format!("cannot read the listing: {e}"));
    }
    let out = Command::new("hs").args(["sys", "pkg", "integrations", "media"]).stdin(Stdio::null()).stderr(Stdio::null()).output();
    match out {
        Ok(o) if o.status.success() => Ok(String::from_utf8_lossy(&o.stdout).into_owned()),
        Ok(o) => Err(format!("the integration listing failed ({})", o.status)),
        Err(e) => Err(format!("cannot run hs: {e}")),
    }
}

/// What the poller says about itself between rounds: it must not repeat a line every 30 seconds.
#[derive(Default)]
struct Said {
    note: String,
    failed: HashMap<String, String>, // package -> the last failure that was logged
    keyless: HashSet<String>,
}

/// GET the sessions of one app with ITS key in its header. The key is read per call and never logged.
fn fetch(ctx: &Ctx, said: &mut Said, app: &App) -> Option<String> {
    let ad = adapter::adapter(&app.package)?;
    let Some(key) = credential_for("media", &app.package).filter(|k| !k.is_empty()) else {
        if said.keyless.insert(app.package.clone()) {
            log(ctx, LogLevel::Warn, &format!("poller: no key handed over for {} (integration-media-{}): not polled", app.package, app.package));
        }
        return None;
    };
    said.keyless.remove(&app.package);
    let url = format!("{}{}", app.url.trim_end_matches('/'), ad.endpoint);
    let got = Client::new().timeout(HTTP_TIMEOUT).header(app.header.clone(), key).get(&url).and_then(|r| r.ok()).map(|r| r.text());
    match got {
        Ok(text) => {
            said.failed.remove(&app.package);
            Some(text)
        }
        Err(e) => {
            let why = match e {
                HttpError::TlsUnsupported => format!("{} is at an https address and the SDK client speaks plain http only (TlsUnsupported): not polled", app.package),
                e => format!("{} did not answer: {e}", app.package),
            };
            if said.failed.get(&app.package) != Some(&why) {
                log(ctx, LogLevel::Warn, &format!("poller: {why}"));
                said.failed.insert(app.package.clone(), why);
            }
            None
        }
    }
}

/// A finished playback: count it in the monthly rollup and write the event (the core does both; the rollup only for a metric kind of this package).
fn record(ctx: &Ctx, f: &Finished) {
    let user = user_name(&f.user);
    let title = clean(&f.title, 120);
    let mut payload = Map::new();
    payload.insert("minutes".into(), json!(f.minutes));
    if !title.is_empty() {
        payload.insert("title".into(), json!(title));
    }
    if let Err(e) = ctx.emit(&Event::new(SESSION_KIND, user.as_str()).text("Playback finished").payload(payload)) {
        log(ctx, LogLevel::Warn, &format!("session of {user} not written: {e}"));
    }
    if let Err(e) = ctx.rollup(SESSION_KIND, &user, 1.0, f64::from(f.minutes)) {
        log(ctx, LogLevel::Warn, &format!("session of {user} not counted: {e}"));
    }
}

fn playing_json(p: &[Playing]) -> Value {
    json!({"sessions": p.iter().map(|s| json!({"app": s.app, "user": s.user, "title": s.title})).collect::<Vec<_>>()})
}

/// The polling loop of the worker thread.
fn worker(ctx: Ctx, health: Arc<Mutex<Health>>, state_dir: PathBuf, interval: f64, min_seconds: f64) {
    let mut poller = Poller::new(state_dir, min_seconds);
    let mut said = Said::default();
    let mut last_playing: Option<Vec<Playing>> = None;
    loop {
        let round = listing().map(|text| {
            let (apps, why) = parse_apps(&integrations::parse(&text));
            if why != said.note {
                let names = apps.iter().map(|a| a.package.as_str()).collect::<Vec<_>>().join(", ");
                let line = match (apps.is_empty(), why.is_empty()) {
                    (_, true) => format!("poller: polling {names}"),
                    (true, false) => format!("poller: {why}"),
                    (false, false) => format!("poller: polling {names} (not polled: {why})"),
                };
                log(&ctx, if why.is_empty() { LogLevel::Info } else { LogLevel::Warn }, &line);
                said.note = why;
            }
            poller.poll(&apps, now_secs(), &mut |a| fetch(&ctx, &mut said, a), &mut |f| record(&ctx, f))
        });
        *health.lock().unwrap() = match round {
            Ok(playing) => {
                if last_playing.as_ref() != Some(&playing) && ctx.snapshot("now-playing", playing_json(&playing)).is_ok() {
                    last_playing = Some(playing);
                }
                Health::ok()
            }
            Err(e) => Health::degraded(format!("poll failed: {e}")),
        };
        thread::sleep(Duration::from_secs_f64(interval));
    }
}

struct Hub {
    health: Arc<Mutex<Health>>,
}

impl Service for Hub {
    fn start(&mut self, _init: &Init, ctx: &Ctx) -> Result<(), String> {
        let interval = env_f64("HS_MEDIA_POLL_SECONDS", 30.0);
        if interval > 0.0 {
            let state_dir = PathBuf::from(std::env::var("HS_MEDIA_STATE_DIR").unwrap_or_else(|_| "/var/lib/hs/media-hub".into()));
            let (ctx, health, min) = (ctx.clone(), self.health.clone(), env_f64("HS_MEDIA_MIN_SECONDS", 60.0));
            thread::spawn(move || worker(ctx, health, state_dir, interval.max(0.05), min));
        }
        Ok(())
    }

    fn tick(&mut self, _ctx: &Ctx) -> Health {
        let h = self.health.lock().unwrap();
        Health { ok: h.ok, text: h.text.clone() }
    }
}

fn main() -> ExitCode {
    run(Hub { health: Arc::new(Mutex::new(Health::ok())) })
}
