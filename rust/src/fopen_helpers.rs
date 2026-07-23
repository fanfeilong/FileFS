use crate::block::EntryLocation;
use crate::error::{Error, Result};
use crate::types::{File, FileSystem, OpenMode, BLOCK_HEAD};

impl FileSystem {
    pub(crate) fn file_handle_from_entry(&mut self, mode: OpenMode, entry: EntryLocation) -> File {
        File {
            mode,
            dir_blockindex: entry.blockindex,
            dir_offset: entry.item_offset,
            file_start_blockindex: entry.start_blockindex,
            file_stop_blockindex: entry.stop_blockindex,
            file_offset: entry.file_offset,
            pos_blockindex: entry.start_blockindex,
            pos_offset: if entry.start_blockindex == 0 {
                0
            } else {
                BLOCK_HEAD as u16
            },
            pos: 0,
            open: true,
        }
    }

    pub(crate) fn append_handle_from_entry(&mut self, mode: OpenMode, entry: EntryLocation) -> Result<File> {
        let mut file = File {
            mode,
            dir_blockindex: entry.blockindex,
            dir_offset: entry.item_offset,
            file_start_blockindex: entry.start_blockindex,
            file_stop_blockindex: entry.stop_blockindex,
            file_offset: entry.file_offset,
            pos_blockindex: entry.start_blockindex,
            pos_offset: if entry.start_blockindex == 0 {
                0
            } else {
                BLOCK_HEAD as u16
            },
            pos: 0,
            open: true,
        };

        if entry.start_blockindex == 0 {
            return Ok(file);
        }

        let len = self.file_length_from_meta(
            entry.start_blockindex,
            entry.stop_blockindex,
            entry.file_offset,
        )?;
        file.pos = len;
        file.pos_blockindex = entry.stop_blockindex;
        file.pos_offset = entry.file_offset;
        Ok(file)
    }

    pub(crate) fn prepare_write_entry(
        &mut self,
        parent_blockindex: u32,
        leaf: &str,
    ) -> Result<(u32, u16)> {
        if let Some(entry) = self.find_entry(parent_blockindex, leaf)? {
            if !entry.is_file {
                return Err(Error::FormatMismatch);
            }
            self.free_file_chain(entry.start_blockindex, entry.stop_blockindex)?;
            self.update_entry_file_meta(entry.blockindex, entry.item_offset, 0, 0, 0)?;
            Ok((entry.blockindex, entry.item_offset))
        } else {
            self.append_dir_entry(parent_blockindex, true, leaf, 0, 0, 0)
        }
    }

    pub(crate) fn prepare_append_entry(
        &mut self,
        parent_blockindex: u32,
        leaf: &str,
    ) -> Result<EntryLocation> {
        if let Some(entry) = self.find_entry(parent_blockindex, leaf)? {
            if !entry.is_file {
                return Err(Error::FormatMismatch);
            }
            Ok(entry)
        } else {
            let (dir_blockindex, dir_offset) =
                self.append_dir_entry(parent_blockindex, true, leaf, 0, 0, 0)?;
            Ok(EntryLocation {
                blockindex: dir_blockindex,
                item_offset: dir_offset,
                is_file: true,
                start_blockindex: 0,
                stop_blockindex: 0,
                file_offset: 0,
            })
        }
    }
}
