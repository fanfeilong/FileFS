use crate::error::{Error, Result};
use crate::types::FileSystem;

impl FileSystem {
    pub fn move_entry(&mut self, from: &str, to_dir: &str) -> Result<()> {
        if !self.is_mounted() {
            return Err(Error::NotMounted);
        }

        let (source_parent, source_leaf, source_trailing) = self.resolve_parent_and_name(from)?;
        if source_leaf == "." || source_leaf == ".." {
            return Err(Error::InvalidName);
        }
        let entry = self
            .find_entry(source_parent, &source_leaf)?
            .ok_or(Error::NotFound)?;
        if source_trailing && entry.is_file {
            return Err(Error::FormatMismatch);
        }

        let (target_parent, _) = self.resolve_dir_block(to_dir)?;
        if self.find_entry(target_parent, &source_leaf)?.is_some() {
            return Err(Error::AlreadyExists);
        }

        let auto = self.ensure_write_transaction()?;
        let result = self.relocate_entry(source_parent, entry, target_parent, &source_leaf);
        match result {
            Ok(()) => self.finish_auto_transaction(auto),
            Err(err) => {
                self.abort_auto_transaction(auto);
                Err(err)
            }
        }
    }
}
