use crate::block::EntryLocation;
use crate::error::{Error, Result};
use crate::types::FileSystem;

impl FileSystem {
    pub(crate) fn relocate_entry(
        &mut self,
        source_parent: u32,
        entry: EntryLocation,
        target_parent: u32,
        target_name: &str,
    ) -> Result<()> {
        if source_parent == target_parent {
            return self.update_entry_name(&entry, target_name);
        }

        if !entry.is_file {
            self.update_entry_parent(&entry, target_parent)?;
        }
        let _ = self.append_dir_entry(
            target_parent,
            entry.is_file,
            target_name,
            entry.start_blockindex,
            entry.stop_blockindex,
            entry.file_offset,
        )?;
        self.remove_entry_from_directory(source_parent, &entry)
    }

    pub fn rename(&mut self, from: &str, to: &str) -> Result<()> {
        if !self.is_mounted() {
            return Err(Error::NotMounted);
        }

        let (source_parent, source_leaf, source_trailing) = self.resolve_parent_and_name(from)?;
        let (target_parent, target_leaf, target_trailing) = self.resolve_parent_and_name(to)?;
        if source_leaf == "." || source_leaf == ".." || target_leaf == "." || target_leaf == ".." {
            return Err(Error::InvalidName);
        }

        let entry = self
            .find_entry(source_parent, &source_leaf)?
            .ok_or(Error::NotFound)?;
        if (source_trailing || target_trailing) && entry.is_file {
            return Err(Error::FormatMismatch);
        }
        if self.find_entry(target_parent, &target_leaf)?.is_some() {
            return Err(Error::AlreadyExists);
        }

        let auto = self.ensure_write_transaction()?;
        let result = self.relocate_entry(source_parent, entry, target_parent, &target_leaf);
        match result {
            Ok(()) => self.finish_auto_transaction(auto),
            Err(err) => {
                self.abort_auto_transaction(auto);
                Err(err)
            }
        }
    }
}
