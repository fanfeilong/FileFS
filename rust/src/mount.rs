use std::fs::{self, File as StdFile, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;

use crate::error::{Error, Result};
use crate::journal::apply_journal;
use crate::types::{
    FileSystem, BLOCK_HEAD, BLOCK_NAME_MAX_SIZE, BLOCK_SIZE, MAGIC, ROOT_BLOCKINDEX, TXN_NONE,
};
use crate::util::{copy_name_into, fixed_name_to_string, flush_file, journal_path_for, put_u16, put_u32};

impl FileSystem {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn mkfs(path: impl AsRef<Path>) -> Result<()> {
        let path = path.as_ref();
        let mut file = StdFile::create(path).map_err(Error::from)?;

        let mut block = [0u8; BLOCK_SIZE];
        block[..4].copy_from_slice(&MAGIC);
        put_u32(&mut block[4..8], 2);
        file.write_all(&block).map_err(Error::from)?;

        block.fill(0);
        let mut k = BLOCK_HEAD;

        block[k] = 0;
        k += 1;
        copy_name_into(&mut block[k..k + BLOCK_NAME_MAX_SIZE], ".");
        k += BLOCK_NAME_MAX_SIZE;
        put_u32(&mut block[k..k + 4], ROOT_BLOCKINDEX);
        k += 4;
        put_u32(&mut block[k..k + 4], ROOT_BLOCKINDEX);
        k += 4;
        put_u16(&mut block[k..k + 2], (BLOCK_HEAD + 2 * 25) as u16);
        k += 2;

        block[k] = 0;
        k += 1;
        copy_name_into(&mut block[k..k + BLOCK_NAME_MAX_SIZE], "..");

        file.write_all(&block).map_err(Error::from)?;
        flush_file(&mut file)?;

        let journal = journal_path_for(path);
        let _ = fs::remove_file(journal);
        Ok(())
    }

    pub fn mount(&mut self, path: impl AsRef<Path>) -> Result<()> {
        let path = path.as_ref();
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .map_err(Error::from)?;

        let mut block0 = [0u8; BLOCK_SIZE];
        file.read_exact(&mut block0).map_err(Error::from)?;
        if block0[..4] != MAGIC {
            return Err(Error::FormatMismatch);
        }
        if crate::util::le_u32(&block0[4..8]) < 2 {
            return Err(Error::FormatMismatch);
        }

        let mut block1 = [0u8; BLOCK_SIZE];
        file.read_exact(&mut block1).map_err(Error::from)?;
        let dot_name = fixed_name_to_string(&block1[(BLOCK_HEAD + 1)..(BLOCK_HEAD + 1 + BLOCK_NAME_MAX_SIZE)]);
        if block1[BLOCK_HEAD] != 0 || dot_name != "." {
            return Err(Error::FormatMismatch);
        }
        let dotdot_offset = BLOCK_HEAD + 25;
        let dotdot_name = fixed_name_to_string(
            &block1[(dotdot_offset + 1)..(dotdot_offset + 1 + BLOCK_NAME_MAX_SIZE)],
        );
        if block1[dotdot_offset] != 0 || dotdot_name != ".." {
            return Err(Error::FormatMismatch);
        }

        self.umount();
        self.image_path = Some(path.to_path_buf());
        self.journal_path = Some(journal_path_for(path));
        self.file = Some(file);
        self.tmp.state = TXN_NONE;
        self.pwd = "/".to_string();
        self.pwd_blockindex = ROOT_BLOCKINDEX;
        self.pwd_tmp.clear();

        apply_journal(self)?;
        Ok(())
    }

    pub fn umount(&mut self) {
        self.file.take();
        self.image_path = None;

        if let Some(path) = self.journal_path.take() {
            let _ = fs::remove_file(path);
        }

        if let Some(file) = self.tmp.cp_file.take() {
            drop(file);
        }
        if let Some(path) = self.tmp.cp_path.take() {
            let _ = fs::remove_file(path);
        }

        if let Some(file) = self.tmp.add_file.take() {
            drop(file);
        }
        if let Some(path) = self.tmp.add_path.take() {
            let _ = fs::remove_file(path);
        }

        self.tmp = Default::default();
        self.pwd.clear();
        self.pwd_blockindex = 0;
        self.pwd_tmp.clear();
    }

    pub fn is_mounted(&self) -> bool {
        self.file.is_some()
    }
}

impl Drop for FileSystem {
    fn drop(&mut self) {
        self.umount();
    }
}
