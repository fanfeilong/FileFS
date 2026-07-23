use std::env;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use filefs::{FileSystem, FileType, BLOCK_SIZE};

struct TestEnv {
    path: PathBuf,
}

impl TestEnv {
    fn new(name: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let path = env::temp_dir().join(format!("filefs-rust-{name}-{nanos}.ffs"));
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(format!("{}-j", path.to_string_lossy()));
        Self { path }
    }

    fn mount(&self) -> FileSystem {
        FileSystem::mkfs(&self.path).expect("mkfs");
        let mut fs = FileSystem::new();
        fs.mount(&self.path).expect("mount");
        fs
    }
}

impl Drop for TestEnv {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
        let _ = std::fs::remove_file(format!("{}-j", self.path.to_string_lossy()));
    }
}

#[test]
fn mkfs_mount_and_cwd() {
    let env = TestEnv::new("mount");
    let fs = env.mount();
    assert!(fs.is_mounted());
    assert_eq!(fs.cwd(), "/");
}

#[test]
fn create_dir_and_chdir() {
    let env = TestEnv::new("mkdir");
    let mut fs = env.mount();
    fs.create_dir("docs").expect("create docs");
    fs.chdir("docs").expect("chdir docs");
    assert_eq!(fs.cwd(), "/docs/");
}

#[test]
fn open_write_read_roundtrip() {
    let env = TestEnv::new("roundtrip");
    let mut fs = env.mount();
    let mut file = fs.open("note.txt", "w").expect("open note");
    let payload = b"hello filefs";
    assert_eq!(fs.write(&mut file, payload).expect("write"), payload.len());
    fs.close(&mut file);

    let mut file = fs.open("note.txt", "r").expect("reopen note");
    let mut buf = [0u8; 64];
    let read = fs.read(&mut file, &mut buf).expect("read");
    assert_eq!(&buf[..read], payload);
}

#[test]
fn copy_rename_and_remove() {
    let env = TestEnv::new("copy");
    let mut fs = env.mount();
    let mut file = fs.open("src.txt", "w").expect("open source");
    fs.write(&mut file, b"copy me").expect("write source");
    fs.copy_file("src.txt", "copy.txt").expect("copy");
    fs.rename("copy.txt", "renamed.txt").expect("rename");
    assert!(fs.file_exists("renamed.txt"));
    fs.remove_file("renamed.txt").expect("remove");
    assert!(!fs.file_exists("renamed.txt"));
}

#[test]
fn read_dir_finds_docs() {
    let env = TestEnv::new("readdir");
    let mut fs = env.mount();
    fs.create_dir("docs").expect("create docs");
    let mut dir = fs.read_dir("/").expect("read root");
    assert_eq!(dir.absolute_path(), "/");
    assert!(dir.any(|entry| entry.name == "docs" && entry.file_type == FileType::Dir));
}

#[test]
fn begin_commit_creates_file() {
    let env = TestEnv::new("txn");
    let mut fs = env.mount();
    fs.begin().expect("begin");
    let mut file = fs.open("txn.txt", "w").expect("open txn");
    fs.write(&mut file, b"x").expect("write txn");
    fs.commit().expect("commit");
    assert!(fs.file_exists("txn.txt"));

    let size = std::fs::metadata(&env.path).expect("metadata").len();
    assert!(size >= (BLOCK_SIZE as u64) * 2);
}
