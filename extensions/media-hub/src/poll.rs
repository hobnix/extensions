//! The poller of the media hub: asks the media apps who is playing, notices when a playback ends, keeps the paths of what was watched for the
//! storage suggestion and builds the poster command of an `imported` event. It knows only `Session` ({id, user, title, path}); the shapes of the
//! apps' answers live in adapter.rs. Every outside thing (the HTTP call, the recording) is a closure that is passed in, so the tests use fakes.
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use hobnix_ext_sdk::integrations::Integration;

use crate::adapter::{adapter, Session};

pub const WATCHED_MAX: usize = 200; // lines kept in watched.tsv

/// A free text without control characters, cut to `n` characters.
pub fn clean(text: &str, n: usize) -> String {
    let s: String = text.chars().map(|c| if c < ' ' || c == '\u{7f}' { ' ' } else { c }).take(n).collect();
    s.trim().to_string()
}

/// The user name of a rollup (the SDK takes 1 to 64 of A-Za-z0-9 and _ . @ -, the first a letter or digit); an empty one is `unknown`.
pub fn user_name(raw: &str) -> String {
    let s: String = clean(raw, 64)
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '@' | '-') { c } else { '_' })
        .collect();
    match s.chars().next() {
        None => "unknown".into(),
        Some(c) if c.is_ascii_alphanumeric() => s,
        Some(_) => format!("u{s}").chars().take(64).collect(),
    }
}

/// An app that can be polled now.
#[derive(Debug, Clone, PartialEq)]
pub struct App {
    pub package: String,
    pub url: String,
    /// The header the key goes in.
    pub header: String,
}

fn header_ok(h: &str) -> bool {
    let mut c = h.chars();
    c.next().is_some_and(|f| f.is_ascii_alphabetic()) && h.len() <= 40 && c.all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// (apps, note) from the rows of `hs sys pkg integrations media`: apps = every provider that can be polled, note = why the others cannot.
/// The key state is the column the SDK calls `key_file` (`-` = the provider has no key: not named). A row without a `key_header` gets the header of
/// the adapter (the listing's default X-Api-Key is not what Jellyfin or Plex read). `https://` is named per provider: the SDK client speaks plain http.
pub fn parse_apps(rows: &[Integration]) -> (Vec<App>, String) {
    let (mut apps, mut notes) = (Vec::new(), Vec::new());
    for r in rows.iter().filter(|r| r.integration == "media") {
        let Some(state) = r.key_file.as_deref() else { continue };
        let Some(ad) = adapter(&r.package) else {
            notes.push(format!("{} has no adapter", r.package));
            continue;
        };
        match (state, r.api_url.as_deref()) {
            (s, _) if s != "ok" => notes.push(format!("the key of {} is {s}", r.package)),
            (_, None) => notes.push(format!("{} has no address", r.package)),
            (_, Some(u)) if u.starts_with("https://") => {
                notes.push(format!("{} is at an https address, the SDK client speaks plain http only (TlsUnsupported)", r.package))
            }
            (_, Some(u)) if !u.starts_with("http://") => notes.push(format!("{} has no http address", r.package)),
            (_, Some(u)) => {
                let h = r.key_header.as_deref().filter(|h| header_ok(h)).unwrap_or(ad.header);
                apps.push(App { package: r.package.clone(), url: u.to_string(), header: h.to_string() });
            }
        }
    }
    if apps.is_empty() && notes.is_empty() {
        notes.push("no media app with a key found".into());
    }
    (apps, notes.join("; "))
}

#[derive(Debug, Clone, PartialEq)]
pub struct Tracked {
    pub user: String,
    pub title: String,
    pub path: String,
    pub start: f64,
    pub last: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Finished {
    pub user: String,
    pub title: String,
    pub path: String,
    pub minutes: u32,
}

/// One poll of one app. `prev` = the sessions of the poll before. Returns the new state and the sessions that are gone now: a playback counts
/// when it is gone and was seen for at least `min_seconds` (a skipped item, a test start); the minutes are between first and last sight, 1 to 1440.
pub fn track(prev: &HashMap<String, Tracked>, sessions: &[Session], now: f64, min_seconds: f64) -> (HashMap<String, Tracked>, Vec<Finished>) {
    let mut new = HashMap::new();
    for s in sessions {
        let start = prev.get(&s.id).map_or(now, |o| o.start);
        new.insert(s.id.clone(), Tracked { user: s.user.clone(), title: s.title.clone(), path: s.path.clone(), start, last: now });
    }
    let mut finished = Vec::new();
    let mut gone: Vec<(&String, &Tracked)> = prev.iter().filter(|(id, _)| !new.contains_key(*id)).collect();
    gone.sort_by(|a, b| a.0.cmp(b.0)); // a stable order
    for (_, o) in gone {
        let seconds = o.last - o.start;
        if seconds >= min_seconds {
            let minutes = (seconds / 60.0).round().clamp(1.0, 1440.0) as u32;
            finished.push(Finished { user: o.user.clone(), title: o.title.clone(), path: o.path.clone(), minutes });
        }
    }
    (new, finished)
}

/// (name, folder) of a path an app reports; the app may be on another system, so both slashes count.
pub fn split_path(path: &str) -> (String, String) {
    let p = clean(path, 500).replace('\\', "/");
    match p.rfind('/') {
        None => (p, String::new()),
        Some(i) => {
            let head = p[..i].trim_end_matches('/');
            let folder = if head.is_empty() && p.starts_with('/') { "/" } else { head };
            (p[i + 1..].to_string(), folder.to_string())
        }
    }
}

/// Keep what was watched: watched.tsv = epoch TAB name TAB folder, the newest WATCHED_MAX, one line per name and folder (the newest).
pub fn remember_watched(state_dir: &Path, finished: &[Finished], now: u64) -> std::io::Result<()> {
    let path = state_dir.join("watched.tsv");
    let mut rows: HashMap<(String, String), u64> = HashMap::new();
    if let Ok(text) = std::fs::read_to_string(&path) {
        for line in text.lines() {
            let t: Vec<&str> = line.split('\t').collect();
            if let (3, Ok(n)) = (t.len(), t[0].parse::<u64>()) {
                rows.insert((t[1].to_string(), t[2].to_string()), n);
            }
        }
    }
    for s in finished {
        let (name, folder) = split_path(&s.path);
        if !name.is_empty() && folder.starts_with('/') {
            rows.insert((name, folder), now);
        }
    }
    let mut keep: Vec<_> = rows.into_iter().collect();
    keep.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    keep.truncate(WATCHED_MAX);
    std::fs::create_dir_all(state_dir)?;
    let mut out = String::new();
    for ((name, folder), t) in keep {
        out.push_str(&format!("{t}\t{name}\t{folder}\n"));
    }
    let tmp = state_dir.join("watched.tsv.new");
    std::fs::write(&tmp, out)?;
    std::fs::rename(&tmp, path)
}

/// Who plays what now, for the snapshot topic now-playing.
#[derive(Debug, Clone, PartialEq)]
pub struct Playing {
    pub app: String,
    pub user: String,
    pub title: String,
}

pub struct Poller {
    prev: HashMap<String, HashMap<String, Tracked>>, // package -> session id -> state
    state_dir: PathBuf,
    min_seconds: f64,
}

impl Poller {
    pub fn new(state_dir: PathBuf, min_seconds: f64) -> Self {
        Poller { prev: HashMap::new(), state_dir, min_seconds }
    }

    /// One round over the apps. `fetch` returns the answer text of an app (None = it did not answer: what we know stays, its sessions do not end),
    /// `record` is called for every finished playback. Returns the sessions playing now.
    pub fn poll(&mut self, apps: &[App], now: f64, fetch: &mut dyn FnMut(&App) -> Option<String>, record: &mut dyn FnMut(&Finished)) -> Vec<Playing> {
        let mut playing = Vec::new();
        for app in apps {
            let Some(ad) = adapter(&app.package) else { continue };
            let Some(text) = fetch(app) else {
                for t in self.prev.get(&app.package).into_iter().flat_map(|m| m.values()) {
                    playing.push(Playing { app: app.package.clone(), user: t.user.clone(), title: t.title.clone() });
                }
                continue;
            };
            let sessions = (ad.parse)(&text);
            let before = self.prev.remove(&app.package).unwrap_or_default();
            let (new, finished) = track(&before, &sessions, now, self.min_seconds);
            self.prev.insert(app.package.clone(), new);
            for f in &finished {
                record(f);
            }
            if !finished.is_empty() {
                let _ = remember_watched(&self.state_dir, &finished, now as u64);
            }
            playing.extend(sessions.iter().map(|s| Playing { app: app.package.clone(), user: s.user.clone(), title: clean(&s.title, 120) }));
        }
        playing
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/media-hub").join(name);
        std::fs::read_to_string(p).expect("fixture")
    }

    fn rows(text: &str) -> Vec<Integration> {
        hobnix_ext_sdk::integrations::parse(text)
    }

    const J: &str = "jellyfin\tmedia\trecipe\thttp://10.0.0.6:8096\tok\t-\tX-Emby-Token\n";
    const R: &str = "radarr\tmedia\trecipe\thttp://10.0.0.5:7878\tok\tkind=movies\tX-Api-Key\n";

    #[test]
    fn providers_with_a_key_and_an_adapter_are_polled() {
        let (apps, why) = parse_apps(&rows(&format!("{J}{R}")));
        assert_eq!(apps, vec![App { package: "jellyfin".into(), url: "http://10.0.0.6:8096".into(), header: "X-Emby-Token".into() }]);
        assert_eq!(why, "radarr has no adapter");
        assert_eq!(parse_apps(&rows(&format!("{R}{J}"))).0.len(), 1);
    }

    #[test]
    fn the_header_of_the_row_or_of_the_adapter() {
        let h = |t: &str| parse_apps(&rows(t)).0[0].header.clone();
        assert_eq!(h("jellyfin\tmedia\trecipe\thttp://x\tok\t-\t-\n"), "X-Emby-Token");
        assert_eq!(h("jellyfin\tmedia\trecipe\thttp://x\tok\t-\tbad header\n"), "X-Emby-Token");
        assert_eq!(h("jellyfin\tmedia\trecipe\thttp://x\tok\t-\n"), "X-Emby-Token"); // a core without the column
        assert_eq!(h("plex\tmedia\trecipe\thttp://x\tok\t-\tX-Own\n"), "X-Own");
    }

    #[test]
    fn why_a_provider_is_not_polled() {
        assert_eq!(parse_apps(&rows("jellyfin\tmedia\trecipe\thttp://x\tlocked\t-\t-\n")), (vec![], "the key of jellyfin is locked".into()));
        assert_eq!(parse_apps(&rows("jellyfin\tmedia\trecipe\thttp://x\t-\t-\t-\n")), (vec![], "no media app with a key found".into()));
        let (apps, why) = parse_apps(&rows("plex\tmedia\trecipe\thttps://plex.lan:32400\tok\t-\t-\n"));
        assert!(apps.is_empty() && why.contains("plex is at an https address") && why.contains("TlsUnsupported"), "{why}");
        assert_eq!(parse_apps(&rows("plex\tmedia\trecipe\t-\tok\t-\t-\n")).1, "plex has no address");
    }

    #[test]
    fn a_playback_counts_when_it_is_gone() {
        let s = |id: &str| Session { id: id.into(), user: "anna".into(), title: "Dune".into(), path: "/m/Dune.mkv".into() };
        let (p, fin) = track(&HashMap::new(), &[s("1")], 1000.0, 60.0);
        assert!(fin.is_empty());
        let (p, fin) = track(&p, &[s("1")], 2800.0, 60.0);
        assert!(fin.is_empty());
        let (_, fin) = track(&p, &[], 2830.0, 60.0);
        assert_eq!(fin.iter().map(|f| f.minutes).collect::<Vec<_>>(), [30]); // last seen 1800 s after the start
        let short = HashMap::from([("1".to_string(), Tracked { user: "a".into(), title: "t".into(), path: "".into(), start: 0.0, last: 40.0 })]);
        assert!(track(&short, &[], 100.0, 60.0).1.is_empty());
        let long = HashMap::from([("1".to_string(), Tracked { user: "a".into(), title: "t".into(), path: "".into(), start: 0.0, last: 1e6 })]);
        assert_eq!(track(&long, &[], 1e6 + 30.0, 60.0).1[0].minutes, 1440);
    }

    #[test]
    fn user_names_are_made_safe() {
        assert_eq!(user_name("carl smith"), "carl_smith");
        assert_eq!(user_name(""), "unknown");
        assert_eq!(user_name(&"a".repeat(99)).len(), 64);
        assert_eq!(user_name("-x"), "u-x");
        assert_eq!(user_name("\u{e9}"), "u_");
    }

    #[test]
    fn the_poller_with_a_fake_app_and_a_fake_recorder() {
        let dir = std::env::temp_dir().join(format!("media-hub-poll-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut poller = Poller::new(dir.clone(), 60.0);
        let apps = vec![App { package: "jellyfin".into(), url: "http://x".into(), header: "X-Emby-Token".into() }];
        let mut answer: Option<String> = Some(fixture("jellyfin-sessions.json"));
        let mut calls: Vec<(String, u32, String)> = Vec::new();
        let round = |poller: &mut Poller, now: f64, answer: &Option<String>, calls: &mut Vec<(String, u32, String)>| {
            let a = answer.clone();
            poller.poll(&apps, now, &mut |_| a.clone(), &mut |f| calls.push((user_name(&f.user), f.minutes, f.title.clone())))
        };
        assert_eq!(round(&mut poller, 10000.0, &answer, &mut calls).len(), 2);
        answer = None;
        assert_eq!(round(&mut poller, 10600.0, &answer, &mut calls).len(), 2, "the app does not answer: the sessions stay");
        answer = Some("[]".into());
        assert!(round(&mut poller, 11200.0, &answer, &mut calls).is_empty());
        assert!(calls.is_empty(), "seen at one poll only (0 s): nothing counted");
        answer = Some(fixture("jellyfin-sessions.json"));
        round(&mut poller, 11260.0, &answer, &mut calls);
        round(&mut poller, 12760.0, &answer, &mut calls);
        answer = Some("[]".into());
        round(&mut poller, 12790.0, &answer, &mut calls);
        calls.sort();
        assert_eq!(calls, [("anna".into(), 25, "Dune".into()), ("carl_smith".into(), 25, "Pilot".into())]);
        let w = std::fs::read_to_string(dir.join("watched.tsv")).unwrap();
        let mut got: Vec<&str> = w.lines().map(|l| l.split_once('\t').unwrap().1).collect();
        got.sort();
        assert_eq!(got, ["Dune.mkv\t/media/movies/Dune (2021)", "S01E01.mkv\t/media/tv/Show"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn paths_split_on_both_slashes() {
        assert_eq!(split_path("/media/movies/Dune.mkv"), ("Dune.mkv".into(), "/media/movies".into()));
        assert_eq!(split_path("C:\\media\\a.mkv"), ("a.mkv".into(), "C:/media".into()));
        assert_eq!(split_path("/a.mkv"), ("a.mkv".into(), "/".into()));
    }
}
