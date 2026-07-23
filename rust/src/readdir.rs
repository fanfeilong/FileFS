use crate::error::{Error, Result};
use crate::types::{
    Dir, DirEntry, FileSystem, FileType, BLOCK_HEAD, BLOCK_ITEM_MAX_COUNT, BLOCK_NAME_MAX_SIZE,
    BLOCK_OFFSET, BLOCK_SIZE, BLOCK_STOP_BLOCKINDEX,
};
use crate::util::{fixed_name_to_string, le_u16, le_u32};

impl FileSystem {
    pub fn read_dir(&mut self, path: &str) -> Result<Dir> {
        if !self.is_mounted() {
            return Err(Error::NotMounted);
        }

        let (blockindex, absolute_path) = if path == "/" {
            (1, "/".to_string())
        } else {
            self.resolve_dir_block(path)?
        };

        let mut block = [0u8; BLOCK_SIZE];
        self.readblock(blockindex, &mut block)?;
        let stop_blockindex = le_u32(&block[BLOCK_STOP_BLOCKINDEX..BLOCK_STOP_BLOCKINDEX + 4]);
        let offset = le_u16(&block[BLOCK_OFFSET..BLOCK_OFFSET + 2]);

        let mut entries = Vec::new();
        let mut current_index = blockindex;
        loop {
            let mut k = BLOCK_HEAD;
            for _ in 0..BLOCK_ITEM_MAX_COUNT {
                let state = block[k];
                k += 1;
                let name = fixed_name_to_string(&block[k..k + BLOCK_NAME_MAX_SIZE]);
                k += BLOCK_NAME_MAX_SIZE;
                let start_blockindex = le_u32(&block[k..k + 4]);
                k += 10;

                let file_type = if name == "." && start_blockindex == 1 {
                    FileType::Root
                } else if name == ".." && start_blockindex == 0 {
                    FileType::Root
                } else if state & 0x01 == 1 {
                    FileType::File
                } else {
                    FileType::Dir
                };
                entries.push(DirEntry { file_type, name });

                if current_index == stop_blockindex && k >= offset as usize {
                    return Ok(Dir {
                        entries,
                        index: 0,
                        absolute_path,
                        open: true,
                    });
                }
            }

            let next = le_u32(&block[4..8]);
            if next == 0 {
                break;
            }
            current_index = next;
            self.readblock(current_index, &mut block)?;
        }

        Ok(Dir {
            entries,
            index: 0,
            absolute_path,
            open: true,
        })
    }
}
