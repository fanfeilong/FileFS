use std::fs::{self, File as StdFile};
use std::io::{Read, Write};

use crate::error::{Error, Result};
use crate::types::{FileSystem, BLOCK_SIZE, MAGIC, TXN_AUTO, TXN_MANUAL, TXN_NONE};
use crate::util::{
    create_temp_file, flush_file, le_u32, put_u32, read_exact_or_eof, rewind_file, set_pos,
};

impl FileSystem {
    pub(crate) fn tmpstart(&mut self, state: u8) -> Result<()> {
        if state == TXN_NONE {
            return Err(Error::Generic);
        }
        if self.file.is_none() {
            return Err(Error::NotMounted);
        }
        if self.tmp.state != TXN_NONE {
            self.tmpstop();
        }

        let mut header = [0u8; 12];
        {
            let main = self.file.as_mut().ok_or(Error::NotMounted)?;
            rewind_file(main)?;
            main.read_exact(&mut header).map_err(Error::from)?;
        }

        self.tmp.total_blocksize = le_u32(&header[4..8]);
        self.tmp.unused_blockhead = le_u32(&header[8..12]);
        self.tmp.new_total_blocksize = self.tmp.total_blocksize;
        self.tmp.new_unused_blockhead = self.tmp.unused_blockhead;

        let (cp_file, cp_path) = create_temp_file("filefs-cp")?;
        let (add_file, add_path) = create_temp_file("filefs-add")?;
        self.tmp.cp_file = Some(cp_file);
        self.tmp.cp_path = Some(cp_path);
        self.tmp.add_file = Some(add_file);
        self.tmp.add_path = Some(add_path);
        self.tmp.pwd = self.pwd.clone();
        self.tmp.pwd_blockindex = self.pwd_blockindex;
        self.tmp.cp_size = 0;
        self.tmp.state = state;
        Ok(())
    }

    pub(crate) fn tmpstop(&mut self) {
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
        self.tmp.cp_size = 0;
        self.tmp.state = TXN_NONE;
    }

    pub(crate) fn ensure_write_transaction(&mut self) -> Result<bool> {
        if self.file.is_none() {
            return Err(Error::NotMounted);
        }
        if self.tmp.state == TXN_NONE {
            self.tmpstart(TXN_AUTO)?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    pub(crate) fn finish_auto_transaction(&mut self, auto_started: bool) -> Result<()> {
        if auto_started {
            self.commit()?;
        }
        Ok(())
    }

    pub(crate) fn abort_auto_transaction(&mut self, auto_started: bool) {
        if auto_started {
            self.tmpstop();
        }
    }

    pub fn begin(&mut self) -> Result<()> {
        if self.file.is_none() {
            return Err(Error::NotMounted);
        }
        if self.tmp.state != TXN_NONE {
            self.rollback();
        }
        self.tmpstart(TXN_MANUAL)
    }

    pub fn rollback(&mut self) {
        if self.file.is_none() {
            return;
        }
        if let Some(path) = self.journal_path.as_ref() {
            let _ = fs::remove_file(path);
        }
        if self.tmp.state != TXN_NONE {
            self.tmpstop();
        }
    }

    pub fn commit(&mut self) -> Result<()> {
        if self.file.is_none() {
            return Err(Error::NotMounted);
        }
        if self.tmp.state == TXN_NONE {
            return Ok(());
        }

        let journal_path = self.journal_path.clone().ok_or(Error::NotMounted)?;
        let mut journal = StdFile::create(&journal_path).map_err(Error::from)?;
        journal.write_all(&[0]).map_err(Error::from)?;

        if self.tmp.total_blocksize != self.tmp.new_total_blocksize
            || self.tmp.unused_blockhead != self.tmp.new_unused_blockhead
        {
            journal.write_all(&[0u8; 4]).map_err(Error::from)?;
            let mut block = [0u8; BLOCK_SIZE];
            block[..4].copy_from_slice(&MAGIC);
            put_u32(&mut block[4..8], self.tmp.new_total_blocksize);
            put_u32(&mut block[8..12], self.tmp.new_unused_blockhead);
            journal.write_all(&block).map_err(Error::from)?;
        }

        let mut chunk = [0u8; BLOCK_SIZE + 4];
        {
            let cp_file = self.tmp.cp_file.as_mut().ok_or(Error::Generic)?;
            rewind_file(cp_file)?;
            while read_exact_or_eof(cp_file, &mut chunk)? {
                journal.write_all(&chunk).map_err(Error::from)?;
            }
        }
        {
            let add_file = self.tmp.add_file.as_mut().ok_or(Error::Generic)?;
            rewind_file(add_file)?;
            while read_exact_or_eof(add_file, &mut chunk)? {
                journal.write_all(&chunk).map_err(Error::from)?;
            }
        }

        rewind_file(&mut journal)?;
        journal.write_all(&[0xff]).map_err(Error::from)?;
        flush_file(&mut journal)?;
        drop(journal);

        let mut journal = StdFile::open(&journal_path).map_err(Error::from)?;
        let mut signal = [0u8; 1];
        journal.read_exact(&mut signal).map_err(Error::from)?;
        while read_exact_or_eof(&mut journal, &mut chunk)? {
            let blockindex = le_u32(&chunk[..4]);
            let main = self.file.as_mut().ok_or(Error::NotMounted)?;
            set_pos(main, blockindex as u64 * BLOCK_SIZE as u64)?;
            main.write_all(&chunk[4..]).map_err(Error::from)?;
        }
        drop(journal);

        let main = self.file.as_mut().ok_or(Error::NotMounted)?;
        flush_file(main)?;
        fs::remove_file(journal_path).map_err(Error::from)?;

        self.pwd = self.tmp.pwd.clone();
        self.pwd_blockindex = self.tmp.pwd_blockindex;
        self.tmpstop();
        Ok(())
    }
}
