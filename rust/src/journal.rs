use std::fs::{self, File as StdFile};
use std::io::Write;

use crate::error::{Error, Result};
use crate::types::{FileSystem, BLOCK_SIZE};
use crate::util::{flush_file, le_u32, read_exact_or_eof, set_pos};

pub(crate) fn apply_journal(fs: &mut FileSystem) -> Result<()> {
    let Some(path) = fs.journal_path.clone() else {
        return Ok(());
    };

    let mut journal = match StdFile::open(&path) {
        Ok(file) => file,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(err) => return Err(Error::from(err)),
    };

    let mut state = [0u8; 1];
    if !read_exact_or_eof(&mut journal, &mut state)? || state[0] != 0xff {
        let _ = fs::remove_file(path);
        return Ok(());
    }

    let mut payload = [0u8; 4 + BLOCK_SIZE];
    while read_exact_or_eof(&mut journal, &mut payload)? {
        let blockindex = le_u32(&payload[..4]);
        let main = fs.file.as_mut().ok_or(Error::NotMounted)?;
        set_pos(main, blockindex as u64 * BLOCK_SIZE as u64)?;
        main.write_all(&payload[4..]).map_err(Error::from)?;
    }

    let main = fs.file.as_mut().ok_or(Error::NotMounted)?;
    flush_file(main)?;
    fs::remove_file(path).map_err(Error::from)?;
    Ok(())
}
