use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::error::{Error, Result};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[inline]
pub(crate) fn le_u32(bytes: &[u8]) -> u32 {
    (bytes[0] as u32)
        | ((bytes[1] as u32) << 8)
        | ((bytes[2] as u32) << 16)
        | ((bytes[3] as u32) << 24)
}

#[inline]
pub(crate) fn put_u32(dst: &mut [u8], value: u32) {
    dst[0] = (value & 0x0000_00ff) as u8;
    dst[1] = ((value & 0x0000_ff00) >> 8) as u8;
    dst[2] = ((value & 0x00ff_0000) >> 16) as u8;
    dst[3] = ((value & 0xff00_0000) >> 24) as u8;
}

#[inline]
pub(crate) fn le_u16(bytes: &[u8]) -> u16 {
    (bytes[0] as u16) | ((bytes[1] as u16) << 8)
}

#[inline]
pub(crate) fn put_u16(dst: &mut [u8], value: u16) {
    dst[0] = (value & 0x00ff) as u8;
    dst[1] = ((value & 0xff00) >> 8) as u8;
}

pub(crate) fn fixed_name_to_string(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

pub(crate) fn fixed_name_eq(bytes: &[u8], name: &str) -> bool {
    let name_bytes = name.as_bytes();
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    &bytes[..end] == name_bytes
}

pub(crate) fn copy_name_into(dst: &mut [u8], name: &str) {
    dst.fill(0);
    let count = dst.len().min(name.len());
    dst[..count].copy_from_slice(&name.as_bytes()[..count]);
}

pub(crate) fn set_pos(file: &mut File, pos: u64) -> Result<()> {
    file.seek(SeekFrom::Start(pos)).map(|_| ()).map_err(Error::from)
}

pub(crate) fn rewind_file(file: &mut File) -> Result<()> {
    set_pos(file, 0)
}

pub(crate) fn flush_file(file: &mut File) -> Result<()> {
    file.flush().map_err(Error::from)?;
    file.sync_all().map_err(Error::from)
}

pub(crate) fn read_exact_or_eof(file: &mut File, buf: &mut [u8]) -> Result<bool> {
    let mut filled = 0usize;
    while filled < buf.len() {
        match file.read(&mut buf[filled..]) {
            Ok(0) => return Ok(false),
            Ok(n) => filled += n,
            Err(err) => return Err(Error::from(err)),
        }
    }
    Ok(true)
}

pub(crate) fn journal_path_for(path: &Path) -> PathBuf {
    PathBuf::from(format!("{}-j", path.to_string_lossy()))
}

pub(crate) fn create_temp_file(prefix: &str) -> Result<(File, PathBuf)> {
    let base = std::env::temp_dir();
    loop {
        let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let path = base.join(format!(
            "{prefix}-{}-{nanos}-{counter}.tmp",
            process::id()
        ));

        match OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(file) => return Ok((file, path)),
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(err) => return Err(Error::from(err)),
        }
    }
}
