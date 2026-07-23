use crate::error::{Error, Result};
use crate::types::{File, FileSystem, OpenMode};

impl FileSystem {
    pub fn copy_file(&mut self, from: &str, to: &str) -> Result<()> {
        if !self.is_mounted() {
            return Err(Error::NotMounted);
        }

        let (source_parent, source_leaf, source_trailing) = self.resolve_parent_and_name(from)?;
        let (target_parent, target_leaf, target_trailing) = self.resolve_parent_and_name(to)?;
        if source_trailing || target_trailing {
            return Err(Error::FormatMismatch);
        }
        if source_leaf == "." || source_leaf == ".." || target_leaf == "." || target_leaf == ".." {
            return Err(Error::InvalidName);
        }

        let source_entry = self
            .find_entry(source_parent, &source_leaf)?
            .ok_or(Error::NotFound)?;
        if !source_entry.is_file {
            return Err(Error::FormatMismatch);
        }
        if self.find_entry(target_parent, &target_leaf)?.is_some() {
            return Err(Error::AlreadyExists);
        }

        let auto = self.ensure_write_transaction()?;
        let result = (|| {
            let mut src = self.file_handle_from_entry(OpenMode::Read, source_entry);
            let (dir_blockindex, dir_offset) = self.append_dir_entry(target_parent, true, &target_leaf, 0, 0, 0)?;
            let mut dst = File {
                mode: OpenMode::Write,
                dir_blockindex,
                dir_offset,
                file_start_blockindex: 0,
                file_stop_blockindex: 0,
                file_offset: 0,
                pos_blockindex: 0,
                pos_offset: 0,
                pos: 0,
                open: true,
            };

            let mut buf = [0u8; 256];
            loop {
                let read = self.read(&mut src, &mut buf)?;
                if read == 0 {
                    break;
                }
                let mut written = 0usize;
                while written < read {
                    written += self.write(&mut dst, &buf[written..read])?;
                }
            }
            Ok(())
        })();

        match result {
            Ok(()) => self.finish_auto_transaction(auto),
            Err(err) => {
                self.abort_auto_transaction(auto);
                Err(err)
            }
        }
    }
}
