use crate::error::{Error, Result};
use crate::types::{FileSystem, BLOCK_HEAD, ENTRY_SIZE};

impl FileSystem {
    pub fn remove_dir(&mut self, path: &str) -> Result<()> {
        if !self.is_mounted() {
            return Err(Error::NotMounted);
        }
        let (parent_blockindex, leaf, _) = self.resolve_parent_and_name(path)?;
        if leaf == "." || leaf == ".." {
            return Err(Error::InvalidName);
        }

        let entry = self
            .find_entry(parent_blockindex, &leaf)?
            .ok_or(Error::NotFound)?;
        if entry.is_file {
            return Err(Error::FormatMismatch);
        }

        let meta = self.read_directory_meta(entry.start_blockindex)?;
        if meta.stop_blockindex != entry.start_blockindex
            || meta.offset > (BLOCK_HEAD + ENTRY_SIZE * 2) as u16
        {
            return Err(Error::NotEmpty);
        }

        let auto = self.ensure_write_transaction()?;
        let result = (|| {
            self.removeblock(entry.start_blockindex)?;
            self.remove_entry_from_directory(parent_blockindex, &entry)
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
