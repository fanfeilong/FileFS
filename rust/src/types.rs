use std::fs::File as StdFile;
use std::path::PathBuf;

pub const BLOCK_SIZE: usize = 512;

pub(crate) const BLOCK_ITEM_MAX_COUNT: usize = 20;
pub(crate) const BLOCK_HEAD: usize = 12;
pub(crate) const BLOCK_NAME_MAX_SIZE: usize = 14;
pub(crate) const BLOCK_START_BLOCKINDEX: usize = 27;
pub(crate) const BLOCK_STOP_BLOCKINDEX: usize = 31;
pub(crate) const BLOCK_OFFSET: usize = 35;
pub(crate) const ENTRY_SIZE: usize = 25;
pub(crate) const ROOT_BLOCKINDEX: u32 = 1;
pub(crate) const MAGIC: [u8; 4] = [0x78, 0x11, 0x45, 0x14];

pub(crate) const TXN_NONE: u8 = 0;
pub(crate) const TXN_AUTO: u8 = 1;
pub(crate) const TXN_MANUAL: u8 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileType {
    File,
    Dir,
    Root,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirEntry {
    pub file_type: FileType,
    pub name: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum OpenMode {
    Read,
    Write,
    Append,
    ReadWrite,
    WriteRead,
    AppendRead,
}

impl OpenMode {
    pub(crate) fn parse(mode: &str) -> Option<Self> {
        match mode {
            "r" => Some(Self::Read),
            "w" => Some(Self::Write),
            "a" => Some(Self::Append),
            "r+" => Some(Self::ReadWrite),
            "w+" => Some(Self::WriteRead),
            "a+" => Some(Self::AppendRead),
            _ => None,
        }
    }

    pub(crate) fn can_read(self) -> bool {
        matches!(
            self,
            Self::Read | Self::ReadWrite | Self::WriteRead | Self::AppendRead
        )
    }

    pub(crate) fn can_write(self) -> bool {
        !matches!(self, Self::Read)
    }
}

#[derive(Debug)]
pub struct File {
    pub(crate) mode: OpenMode,
    pub(crate) dir_blockindex: u32,
    pub(crate) dir_offset: u16,
    pub(crate) file_start_blockindex: u32,
    pub(crate) file_stop_blockindex: u32,
    pub(crate) file_offset: u16,
    pub(crate) pos_blockindex: u32,
    pub(crate) pos_offset: u16,
    pub(crate) pos: u64,
    pub(crate) open: bool,
}

impl File {
    pub fn is_open(&self) -> bool {
        self.open
    }

    pub fn close(&mut self) {
        self.open = false;
    }
}

impl Drop for File {
    fn drop(&mut self) {
        self.close();
    }
}

#[derive(Debug)]
pub struct Dir {
    pub(crate) entries: Vec<DirEntry>,
    pub(crate) index: usize,
    pub(crate) absolute_path: String,
    pub(crate) open: bool,
}

impl Dir {
    pub fn is_open(&self) -> bool {
        self.open
    }

    pub fn close(&mut self) {
        self.open = false;
    }

    pub fn absolute_path(&self) -> &str {
        &self.absolute_path
    }
}

impl Iterator for Dir {
    type Item = DirEntry;

    fn next(&mut self) -> Option<Self::Item> {
        if !self.open {
            return None;
        }
        let entry = self.entries.get(self.index)?.clone();
        self.index += 1;
        Some(entry)
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        self.close();
    }
}

#[derive(Debug, Default)]
pub(crate) struct TmpState {
    pub(crate) state: u8,
    pub(crate) pwd: String,
    pub(crate) pwd_blockindex: u32,
    pub(crate) cp_file: Option<StdFile>,
    pub(crate) add_file: Option<StdFile>,
    pub(crate) cp_path: Option<PathBuf>,
    pub(crate) add_path: Option<PathBuf>,
    pub(crate) cp_size: u32,
    pub(crate) total_blocksize: u32,
    pub(crate) unused_blockhead: u32,
    pub(crate) new_total_blocksize: u32,
    pub(crate) new_unused_blockhead: u32,
}

#[derive(Debug, Default)]
pub struct FileSystem {
    pub(crate) image_path: Option<PathBuf>,
    pub(crate) journal_path: Option<PathBuf>,
    pub(crate) file: Option<StdFile>,
    pub(crate) tmp: TmpState,
    pub(crate) pwd: String,
    pub(crate) pwd_blockindex: u32,
    pub(crate) pwd_tmp: String,
}
