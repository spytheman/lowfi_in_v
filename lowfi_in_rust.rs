use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, SyncSender};
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static SONGS: OnceLock<Vec<Song>> = OnceLock::new();
static SONG_COUNTER: AtomicU64 = AtomicU64::new(0);
static RNG_COUNTER: AtomicU64 = AtomicU64::new(0);
static SONG_LOCAL_DIR: OnceLock<PathBuf> = OnceLock::new();

#[derive(Clone, Debug)]
struct Song {
    url: String,
    title: String,
    #[allow(dead_code)]
    number: usize,
}

impl Song {
    fn local_path(&self) -> PathBuf {
        song_local_dir().join(format!("{}.mp3", fnv1a_64(&self.url)))
    }
}

struct App {
    downloaded: SyncSender<Song>,
}

fn song_local_dir() -> &'static PathBuf {
    SONG_LOCAL_DIR.get_or_init(|| env::temp_dir().join("lowfi"))
}

fn songs() -> &'static [Song] {
    SONGS.get_or_init(create_songs).as_slice()
}

fn create_songs() -> Vec<Song> {
    let content: Vec<&str> = include_str!("chillhop.txt").lines().collect();
    let baseurl = content.first().copied().unwrap_or("");
    content
        .iter()
        .skip(1)
        .map(|line| new_song(&format!("{}{}", baseurl, line)))
        .collect()
}

fn new_song(line: &str) -> Song {
    let (url, title) = line.split_once('!').unwrap_or((line, ""));
    Song {
        url: url.to_string(),
        title: title.to_string(),
        number: 0,
    }
}

fn pick_random_song() -> Option<Song> {
    let list = songs();
    if list.is_empty() {
        return None;
    }
    let idx = random_index(list.len());
    Some(list[idx].clone())
}

fn random_index(len: usize) -> usize {
    if len == 0 {
        return 0;
    }

    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;
    let counter = RNG_COUNTER.fetch_add(1, Ordering::Relaxed);
    let mut x = nanos ^ counter.wrapping_mul(0x9e37_79b9_7f4a_7c15);
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    (x as usize) % len
}

fn add_random_song(app: &App) {
    let Some(song) = pick_random_song() else {
        return;
    };

    let counter = SONG_COUNTER.fetch_add(1, Ordering::SeqCst) as usize + 1;
    let downloaded = app.downloaded.clone();
    thread::spawn(move || download_local_file(song, counter, downloaded));
}

fn download_local_file(osong: Song, counter: usize, downloaded: SyncSender<Song>) {
    let song = Song {
        number: counter,
        ..osong
    };
    let lpath = song.local_path();

    if !lpath.exists() {
        for _ in 0..5 {
            if wget(&song.url, &lpath) {
                break;
            }
            thread::sleep(Duration::from_millis(500));
        }
    }

    let _ = downloaded.send(song);
}

fn wget(url: &str, output_path: &Path) -> bool {
    Command::new("wget")
        .arg("--quiet")
        .arg(format!("--output-document={}", output_path.display()))
        .arg(url)
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn remove_song(song: &Song) {
    let _ = fs::remove_file(song.local_path());
}

fn add_another(app: &App, song: Song) {
    remove_song(&song);
    add_random_song(app);
}

fn find_abs_path_of_executable(cmd: &str) -> Option<PathBuf> {
    let path_var = env::var_os("PATH")?;
    for dir in env::split_paths(&path_var) {
        let candidate = dir.join(cmd);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn should_be_present(cmd: &str) {
    if find_abs_path_of_executable(cmd).is_none() {
        eprintln!("This program needs {} to work.", cmd);
        std::process::exit(1);
    }
}

fn fnv1a_64(text: &str) -> u64 {
    const OFFSET_BASIS: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;

    let mut hash = OFFSET_BASIS;
    for &byte in text.as_bytes() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(PRIME);
    }
    hash
}

fn main() {
    should_be_present("mpg321");
    should_be_present("wget");

    fs::create_dir_all(song_local_dir()).ok();
    println!("Local folder: {}", song_local_dir().display());

    let (downloaded_tx, downloaded_rx) = sync_channel::<Song>(5);
    let app = App {
        downloaded: downloaded_tx,
    };

    for _ in 0..5 {
        add_random_song(&app);
    }

    loop {
        let song = downloaded_rx.recv().expect("download channel closed");
        println!("Playing \"{}\" from URL: {:<40} ...", song.title, song.url);

        let status = Command::new("mpg321")
            .arg("--quiet")
            .arg(song.local_path())
            .status();
        let res = status.ok().and_then(|s| s.code()).unwrap_or(-1);
        dbg!(res);

        if res == 4 {
            eprintln!("mpg321 was interrupted by Ctrl-C. Good bye.");
            std::process::exit(1);
        }

        add_another(&app, song);
    }
}
