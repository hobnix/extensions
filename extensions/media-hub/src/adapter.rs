//! The adapters of the poller: where to ask an app and how to read its answer. UNVERIFIED: written from the public API descriptions of
//! Jellyfin and Plex, never run against a real server; the fixtures in tests/fixtures/media-hub/ are hand-made samples of those shapes.
//! Hardware test step 2 checks them. Nothing else of the poller knows these shapes.
use serde_json::Value;

/// A playback an app reports now.
#[derive(Debug, Clone, PartialEq)]
pub struct Session {
    pub id: String,
    pub user: String,
    pub title: String,
    pub path: String,
}

pub struct Adapter {
    /// The package name `hs pkg integrations media` lists.
    pub package: &'static str,
    /// GET <api_url><endpoint>.
    pub endpoint: &'static str,
    /// The header the API key goes in when the listing row names none.
    pub header: &'static str,
    /// The sessions that play something now; a broken answer is an empty list.
    pub parse: fn(&str) -> Vec<Session>,
}

pub const ADAPTERS: [Adapter; 2] = [
    Adapter { package: "jellyfin", endpoint: "/Sessions", header: "X-Emby-Token", parse: parse_jellyfin },
    Adapter { package: "plex", endpoint: "/status/sessions", header: "X-Plex-Token", parse: parse_plex },
];

pub fn adapter(package: &str) -> Option<&'static Adapter> {
    ADAPTERS.iter().find(|a| a.package == package)
}

/// A JSON value as text: a string as is, a number or a bool as written, anything else empty.
fn text(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

fn truthy(v: Option<&Value>) -> bool {
    match v {
        Some(Value::String(s)) => !s.is_empty(),
        Some(Value::Number(n)) => n.as_f64() != Some(0.0),
        Some(Value::Bool(b)) => *b,
        _ => false,
    }
}

fn parse_jellyfin(body: &str) -> Vec<Session> {
    let Ok(Value::Array(list)) = serde_json::from_str::<Value>(body) else { return Vec::new() };
    list.iter()
        .filter_map(|s| {
            let item = s.get("NowPlayingItem").filter(|i| i.is_object())?;
            truthy(s.get("Id")).then(|| Session {
                id: text(s.get("Id")),
                user: text(s.get("UserName")),
                title: text(item.get("Name")),
                path: text(item.get("Path")),
            })
        })
        .collect()
}

fn parse_plex(body: &str) -> Vec<Session> {
    let Ok(v) = serde_json::from_str::<Value>(body) else { return Vec::new() };
    let Some(Value::Array(meta)) = v.get("MediaContainer").and_then(|m| m.get("Metadata")) else { return Vec::new() };
    meta.iter()
        .filter(|m| m.is_object())
        .filter_map(|m| {
            let sess = m.get("Session").filter(|s| s.is_object());
            let key = sess
                .and_then(|s| s.get("id"))
                .filter(|v| truthy(Some(v)))
                .or_else(|| m.get("sessionKey").filter(|v| truthy(Some(v))))?;
            let path = m.pointer("/Media/0/Part/0/file");
            let user = m.get("User").filter(|u| u.is_object()).and_then(|u| u.get("title"));
            Some(Session { id: text(Some(key)), user: text(user), title: text(m.get("title")), path: text(path) })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/media-hub").join(name);
        std::fs::read_to_string(p).expect("fixture")
    }

    #[test]
    fn jellyfin_only_sessions_that_play_something() {
        let s = parse_jellyfin(&fixture("jellyfin-sessions.json"));
        assert_eq!(s.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["s1", "s3"]);
        assert_eq!((s[0].user.as_str(), s[0].title.as_str(), s[0].path.as_str()), ("anna", "Dune", "/media/movies/Dune (2021)/Dune.mkv"));
    }

    #[test]
    fn plex_one_session() {
        let s = parse_plex(&fixture("plex-sessions.json"));
        let want = Session { id: "abc123".into(), user: "dora".into(), title: "Arrival".into(), path: "/data/movies/Arrival (2016)/Arrival.mkv".into() };
        assert_eq!(s, vec![want]);
    }

    #[test]
    fn broken_answers_are_empty() {
        assert!(parse_jellyfin("<html>").is_empty() && parse_jellyfin("{}").is_empty());
        assert!(parse_plex("{}").is_empty() && parse_plex("nope").is_empty());
    }

    #[test]
    fn an_app_without_an_adapter_is_unknown() {
        assert!(adapter("radarr").is_none() && adapter("plex").is_some());
    }
}
