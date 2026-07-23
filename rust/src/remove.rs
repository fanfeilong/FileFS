use crate::error::{Error, Result};
use crate::types::FileSystem;

impl FileSystem {
    pub fn remove_file(&mut self, path: &str) -> Result<()> {
        if !self.is_mounted() {
            return Err(Error::NotMounted);
        }
        let (parent_blockindex, leaf, trailing) = self.resolve_parent_and_name(path)?;
        if trailing || leaf == "." || leaf == ".." {
            return Err(Error::InvalidName);
        }

        let entry = self
            .find_entry(parent_blockindex, &leaf)?
            .ok_or(Error::NotFound)?;
        if !entry.is_file {
            return Err(Error::FormatMismatch);
        }

        let auto = self.ensure_write_transaction()?;
        let result = (|| {
            self.free_file_chain(entry.start_blockindex, entry.stop_blockindex)?;
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
