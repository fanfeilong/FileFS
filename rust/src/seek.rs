use std::io::SeekFrom;

use crate::error::{Error, Result};
use crate::types::{File, FileSystem};

impl FileSystem {
    pub fn seek(&mut self, file: &mut File, pos: SeekFrom) -> Result<u64> {
        if !self.is_mounted() {
            return Err(Error::NotMounted);
        }
        if !file.is_open() {
            return Err(Error::ClosedHandle);
        }

        let len = self.file_length_from_meta(
            file.file_start_blockindex,
            file.file_stop_blockindex,
            file.file_offset,
        )?;

        let current = file.pos as i128;
        let target = match pos {
            SeekFrom::Start(off) => off as i128,
            SeekFrom::Current(off) => current + off as i128,
            SeekFrom::End(off) => len as i128 + off as i128,
        }
        .clamp(0, len as i128) as u64;

        if file.file_start_blockindex == 0 {
            file.pos = 0;
            file.pos_blockindex = 0;
            file.pos_offset = 0;
            return Ok(0);
        }

        let (blockindex, offset) = self.locate_file_position(
            file.file_start_blockindex,
            file.file_stop_blockindex,
            file.file_offset,
            target,
        )?;
        file.pos = target;
        file.pos_blockindex = blockindex;
        file.pos_offset = offset;
        Ok(target)
    }

    pub fn stream_position(&mut self, file: &File) -> Result<u64> {
        if !self.is_mounted() {
            return Err(Error::NotMounted);
        }
        if !file.is_open() {
            return Err(Error::ClosedHandle);
        }
        Ok(file.pos)
    }

    pub fn rewind(&mut self, file: &mut File) -> Result<()> {
        self.seek(file, SeekFrom::Start(0)).map(|_| ())
    }
}

impl File {
    pub fn seek_in(&mut self, fs: &mut FileSystem, pos: SeekFrom) -> Result<u64> {
        fs.seek(self, pos)
    }

    pub fn stream_position_in(&self, fs: &mut FileSystem) -> Result<u64> {
        fs.stream_position(self)
    }

    pub fn rewind_in(&mut self, fs: &mut FileSystem) -> Result<()> {
        fs.rewind(self)
    }
}
