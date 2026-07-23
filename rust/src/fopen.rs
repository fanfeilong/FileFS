use crate::error::{Error, Result};
use crate::types::{File, FileSystem, OpenMode};

impl FileSystem {
    pub fn open(&mut self, path: &str, mode: &str) -> Result<File> {
        if !self.is_mounted() {
            return Err(Error::NotMounted);
        }
        let mode = OpenMode::parse(mode).ok_or(Error::InvalidMode)?;
        let (parent_blockindex, leaf, trailing) = self.resolve_parent_and_name(path)?;
        if trailing || leaf == "." || leaf == ".." {
            return Err(Error::InvalidName);
        }

        match mode {
            OpenMode::Read | OpenMode::ReadWrite => {
                let entry = self
                    .find_entry(parent_blockindex, &leaf)?
                    .ok_or(Error::NotFound)?;
                if !entry.is_file {
                    return Err(Error::FormatMismatch);
                }
                Ok(self.file_handle_from_entry(mode, entry))
            }
            OpenMode::Write | OpenMode::WriteRead => {
                let auto = self.ensure_write_transaction()?;
                let result = (|| {
                    let (dir_blockindex, dir_offset) = self.prepare_write_entry(parent_blockindex, &leaf)?;
                    Ok(File {
                        mode,
                        dir_blockindex,
                        dir_offset,
                        file_start_blockindex: 0,
                        file_stop_blockindex: 0,
                        file_offset: 0,
                        pos_blockindex: 0,
                        pos_offset: 0,
                        pos: 0,
                        open: true,
                    })
                })();
                match result {
                    Ok(file) => {
                        self.finish_auto_transaction(auto)?;
                        Ok(file)
                    }
                    Err(err) => {
                        self.abort_auto_transaction(auto);
                        Err(err)
                    }
                }
            }
            OpenMode::Append | OpenMode::AppendRead => {
                let auto = self.ensure_write_transaction()?;
                let result = (|| {
                    let entry = self.prepare_append_entry(parent_blockindex, &leaf)?;
                    self.append_handle_from_entry(mode, entry)
                })();
                match result {
                    Ok(file) => {
                        self.finish_auto_transaction(auto)?;
                        Ok(file)
                    }
                    Err(err) => {
                        self.abort_auto_transaction(auto);
                        Err(err)
                    }
                }
            }
        }
    }
}
