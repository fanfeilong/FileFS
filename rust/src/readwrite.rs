use crate::error::{Error, Result};
use crate::types::{File, FileSystem, BLOCK_HEAD, BLOCK_SIZE};
use crate::util::{le_u32, put_u32};

impl FileSystem {
    fn ensure_open_file<'a>(&self, file: &'a mut File) -> Result<&'a mut File> {
        if !self.is_mounted() {
            return Err(Error::NotMounted);
        }
        if !file.open {
            return Err(Error::ClosedHandle);
        }
        Ok(file)
    }

    pub fn read(&mut self, file: &mut File, buf: &mut [u8]) -> Result<usize> {
        let file = self.ensure_open_file(file)?;
        if !file.mode.can_read() {
            return Err(Error::FormatMismatch);
        }
        if file.pos_blockindex == 0 || buf.is_empty() {
            return Ok(0);
        }

        let mut total = 0usize;
        let mut blockindex = file.pos_blockindex;
        let mut pos_offset = file.pos_offset;

        while total < buf.len() {
            let mut block = [0u8; BLOCK_SIZE];
            self.readblock(blockindex, &mut block)?;
            let next = le_u32(&block[4..8]);
            let limit = if blockindex == file.file_stop_blockindex {
                file.file_offset as usize
            } else {
                BLOCK_SIZE
            };

            if pos_offset as usize >= limit {
                break;
            }

            let available = limit - pos_offset as usize;
            let count = available.min(buf.len() - total);
            buf[total..total + count]
                .copy_from_slice(&block[pos_offset as usize..pos_offset as usize + count]);
            total += count;
            file.pos += count as u64;
            pos_offset += count as u16;

            if pos_offset as usize == BLOCK_SIZE && next != 0 && blockindex != file.file_stop_blockindex {
                blockindex = next;
                pos_offset = BLOCK_HEAD as u16;
            }
        }

        file.pos_blockindex = blockindex;
        file.pos_offset = pos_offset;
        Ok(total)
    }

    pub fn write(&mut self, file: &mut File, buf: &[u8]) -> Result<usize> {
        let file = self.ensure_open_file(file)?;
        if !file.mode.can_write() {
            return Err(Error::FormatMismatch);
        }
        if buf.is_empty() {
            return Ok(0);
        }

        let auto = self.ensure_write_transaction()?;
        let original_len = self.file_length_from_meta(
            file.file_start_blockindex,
            file.file_stop_blockindex,
            file.file_offset,
        )?;

        let result = (|| {
            let mut current_blockindex = file.pos_blockindex;
            let mut current_offset = file.pos_offset;
            let mut current_block = [0u8; BLOCK_SIZE];
            let mut next_blockindex;

            if current_blockindex == 0 {
                let new_blockindex = self.genblockindex()?;
                self.writeblock(new_blockindex, &[0u8; BLOCK_SIZE])?;
                self.update_entry_file_meta(
                    file.dir_blockindex,
                    file.dir_offset,
                    new_blockindex,
                    new_blockindex,
                    BLOCK_HEAD as u16,
                )?;
                file.file_start_blockindex = new_blockindex;
                file.file_stop_blockindex = new_blockindex;
                file.file_offset = BLOCK_HEAD as u16;
                file.pos_blockindex = new_blockindex;
                file.pos_offset = BLOCK_HEAD as u16;
                current_blockindex = new_blockindex;
                current_offset = BLOCK_HEAD as u16;
                next_blockindex = 0;
            } else {
                self.readblock(current_blockindex, &mut current_block)?;
                next_blockindex = le_u32(&current_block[4..8]);
            }

            let mut written = 0usize;
            while written < buf.len() {
                if current_offset as usize == BLOCK_SIZE {
                    if next_blockindex == 0 {
                        let new_blockindex = self.genblockindex()?;
                        let mut new_block = [0u8; BLOCK_SIZE];
                        put_u32(&mut new_block[8..12], current_blockindex);
                        put_u32(&mut current_block[4..8], new_blockindex);
                        self.writeblock(current_blockindex, &current_block)?;
                        current_blockindex = new_blockindex;
                        current_block = new_block;
                        current_offset = BLOCK_HEAD as u16;
                        next_blockindex = 0;
                    } else {
                        current_blockindex = next_blockindex;
                        self.readblock(current_blockindex, &mut current_block)?;
                        next_blockindex = le_u32(&current_block[4..8]);
                        current_offset = BLOCK_HEAD as u16;
                    }
                }

                let available = BLOCK_SIZE - current_offset as usize;
                let count = available.min(buf.len() - written);
                current_block[current_offset as usize..current_offset as usize + count]
                    .copy_from_slice(&buf[written..written + count]);
                written += count;
                current_offset += count as u16;
                file.pos += count as u64;
                self.writeblock(current_blockindex, &current_block)?;
            }

            file.pos_blockindex = current_blockindex;
            file.pos_offset = current_offset;

            if file.pos > original_len {
                file.file_stop_blockindex = current_blockindex;
                file.file_offset = current_offset;
                self.update_entry_file_meta(
                    file.dir_blockindex,
                    file.dir_offset,
                    file.file_start_blockindex,
                    current_blockindex,
                    current_offset,
                )?;
            }

            Ok(written)
        })();

        match result {
            Ok(written) => {
                self.finish_auto_transaction(auto)?;
                Ok(written)
            }
            Err(err) => {
                self.abort_auto_transaction(auto);
                Err(err)
            }
        }
    }

    pub fn close(&mut self, file: &mut File) {
        let _ = self;
        file.close();
    }
}

impl File {
    pub fn read_from(&mut self, fs: &mut FileSystem, buf: &mut [u8]) -> Result<usize> {
        fs.read(self, buf)
    }

    pub fn write_to(&mut self, fs: &mut FileSystem, buf: &[u8]) -> Result<usize> {
        fs.write(self, buf)
    }
}
