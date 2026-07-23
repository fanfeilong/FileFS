use crate::types::{FileSystem, ROOT_BLOCKINDEX};

impl FileSystem {
    fn stat_path(&mut self, path: &str) -> Option<bool> {
        if !self.is_mounted() || path.is_empty() {
            return None;
        }
        if path == "/" {
            return Some(false);
        }
        let Ok((parent_blockindex, leaf, _)) = self.resolve_parent_and_name(path) else {
            return None;
        };
        let Ok(entry) = self.find_entry(parent_blockindex, &leaf) else {
            return None;
        };
        entry.map(|found| found.is_file)
    }

    pub fn file_exists(&mut self, path: &str) -> bool {
        matches!(self.stat_path(path), Some(true))
    }

    pub fn dir_exists(&mut self, path: &str) -> bool {
        if path == "/" {
            return self.is_mounted() && self.active_pwd_blockindex() >= ROOT_BLOCKINDEX;
        }
        matches!(self.stat_path(path), Some(false))
    }
}
