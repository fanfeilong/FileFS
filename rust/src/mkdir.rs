use crate::error::{Error, Result};
use crate::types::FileSystem;

impl FileSystem {
    pub fn create_dir(&mut self, path: &str) -> Result<()> {
        if !self.is_mounted() {
            return Err(Error::NotMounted);
        }
        let (parent_blockindex, leaf, _) = self.resolve_parent_and_name(path)?;
        if leaf == "." || leaf == ".." {
            return Err(Error::InvalidName);
        }
        if let Some(entry) = self.find_entry(parent_blockindex, &leaf)? {
            return Err(if entry.is_file {
                Error::AlreadyExists
            } else {
                Error::AlreadyExists
            });
        }

        let auto = self.ensure_write_transaction()?;
        let result = (|| {
            let new_dir_blockindex = self.create_dir_block(parent_blockindex)?;
            let _ = self.append_dir_entry(parent_blockindex, false, &leaf, new_dir_blockindex, 0, 0)?;
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
