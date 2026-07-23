use std::io::{Read, Write};

use crate::error::{Error, Result};
use crate::types::{
    FileSystem, BLOCK_HEAD, BLOCK_ITEM_MAX_COUNT, BLOCK_NAME_MAX_SIZE, BLOCK_OFFSET, BLOCK_SIZE,
    BLOCK_START_BLOCKINDEX, BLOCK_STOP_BLOCKINDEX, ENTRY_SIZE, TXN_NONE,
};
use crate::util::{copy_name_into, fixed_name_eq, le_u16, le_u32, put_u16, put_u32, set_pos};

#[derive(Debug, Clone, Copy)]
pub(crate) struct DirectoryMeta {
    pub(crate) stop_blockindex: u32,
    pub(crate) offset: u16,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct EntryLocation {
    pub(crate) blockindex: u32,
    pub(crate) item_offset: u16,
    pub(crate) is_file: bool,
    pub(crate) start_blockindex: u32,
    pub(crate) stop_blockindex: u32,
    pub(crate) file_offset: u16,
}

impl FileSystem {
    pub(crate) fn readblock(&mut self, blockindex: u32, block: &mut [u8; BLOCK_SIZE]) -> Result<()> {
        if self.file.is_none() {
            return Err(Error::NotMounted);
        }

        let pos = blockindex as u64 * BLOCK_SIZE as u64;
        let mut prefix = [0u8; 4];
        {
            let main = self.file.as_mut().ok_or(Error::NotMounted)?;
            set_pos(main, pos)?;
            if main.read_exact(&mut prefix).is_err() {
                if self.tmp.state == TXN_NONE || blockindex < self.tmp.total_blocksize {
                    return Err(Error::Generic);
                }
                let addindex = blockindex - self.tmp.total_blocksize;
                let add_pos = addindex as u64 * (BLOCK_SIZE as u64 + 4) + 4;
                let add = self.tmp.add_file.as_mut().ok_or(Error::Generic)?;
                set_pos(add, add_pos)?;
                add.read_exact(block).map_err(Error::from)?;
                return Ok(());
            }
        }

        if self.tmp.state == TXN_NONE {
            block[..4].copy_from_slice(&prefix);
            let main = self.file.as_mut().ok_or(Error::NotMounted)?;
            main.read_exact(&mut block[4..]).map_err(Error::from)?;
            return Ok(());
        }

        let cpindex = le_u32(&prefix);
        let cp_pos = cpindex as u64 * (BLOCK_SIZE as u64 + 4);
        let mut origin = [0u8; 4];
        let mut used_copy = false;
        {
            let cp = self.tmp.cp_file.as_mut().ok_or(Error::Generic)?;
            set_pos(cp, cp_pos)?;
            if cp.read_exact(&mut origin).is_ok() && le_u32(&origin) == blockindex {
                cp.read_exact(block).map_err(Error::from)?;
                used_copy = true;
            }
        }

        if used_copy {
            return Ok(());
        }

        block[..4].copy_from_slice(&prefix);
        let main = self.file.as_mut().ok_or(Error::NotMounted)?;
        set_pos(main, pos + 4)?;
        main.read_exact(&mut block[4..]).map_err(Error::from)?;
        Ok(())
    }

    pub(crate) fn writeblock(&mut self, blockindex: u32, block: &[u8; BLOCK_SIZE]) -> Result<()> {
        if self.tmp.state == TXN_NONE {
            return Err(Error::Generic);
        }

        let pos = blockindex as u64 * BLOCK_SIZE as u64;
        let mut prefix = [0u8; 4];
        let read_main_ok = {
            let main = self.file.as_mut().ok_or(Error::NotMounted)?;
            set_pos(main, pos)?;
            main.read_exact(&mut prefix).is_ok()
        };

        if !read_main_ok {
            if blockindex < self.tmp.total_blocksize {
                return Err(Error::Generic);
            }
            let addindex = blockindex - self.tmp.total_blocksize;
            let add_pos = addindex as u64 * (BLOCK_SIZE as u64 + 4) + 4;
            let add = self.tmp.add_file.as_mut().ok_or(Error::Generic)?;
            set_pos(add, add_pos)?;
            add.write_all(block).map_err(Error::from)?;
            return Ok(());
        }

        let mut cpindex = le_u32(&prefix);
        let cp_pos = cpindex as u64 * (BLOCK_SIZE as u64 + 4);
        let mut origin = [0u8; 4];
        let existing_copy = {
            let cp = self.tmp.cp_file.as_mut().ok_or(Error::Generic)?;
            set_pos(cp, cp_pos)?;
            cp.read_exact(&mut origin).is_ok() && le_u32(&origin) == blockindex
        };

        if existing_copy {
            let cp = self.tmp.cp_file.as_mut().ok_or(Error::Generic)?;
            set_pos(cp, cp_pos + 4)?;
            cp.write_all(block).map_err(Error::from)?;
            return Ok(());
        }

        cpindex = self.tmp.cp_size;
        let new_cp_pos = cpindex as u64 * (BLOCK_SIZE as u64 + 4);
        {
            let cp = self.tmp.cp_file.as_mut().ok_or(Error::Generic)?;
            set_pos(cp, new_cp_pos)?;
            let mut raw = [0u8; 4];
            put_u32(&mut raw, blockindex);
            cp.write_all(&raw).map_err(Error::from)?;
            cp.write_all(block).map_err(Error::from)?;
        }
        {
            let main = self.file.as_mut().ok_or(Error::NotMounted)?;
            set_pos(main, pos)?;
            let mut raw = [0u8; 4];
            put_u32(&mut raw, cpindex);
            main.write_all(&raw).map_err(Error::from)?;
        }
        self.tmp.cp_size += 1;
        Ok(())
    }

    pub(crate) fn removeblock(&mut self, blockindex: u32) -> Result<()> {
        if self.tmp.state == TXN_NONE {
            return Err(Error::Generic);
        }

        let pos = blockindex as u64 * BLOCK_SIZE as u64;
        let mut prefix = [0u8; 4];
        let read_main_ok = {
            let main = self.file.as_mut().ok_or(Error::NotMounted)?;
            set_pos(main, pos)?;
            main.read_exact(&mut prefix).is_ok()
        };

        if !read_main_ok {
            if blockindex < self.tmp.total_blocksize {
                return Err(Error::Generic);
            }
            let addindex = blockindex - self.tmp.total_blocksize;
            let add_pos = addindex as u64 * (BLOCK_SIZE as u64 + 4) + 8;
            let add = self.tmp.add_file.as_mut().ok_or(Error::Generic)?;
            set_pos(add, add_pos)?;
            let mut raw = [0u8; 4];
            put_u32(&mut raw, self.tmp.new_unused_blockhead);
            add.write_all(&raw).map_err(Error::from)?;
            self.tmp.new_unused_blockhead = blockindex;
            return Ok(());
        }

        let mut cpindex = le_u32(&prefix);
        let cp_pos = cpindex as u64 * (BLOCK_SIZE as u64 + 4);
        let mut origin = [0u8; 4];
        let existing_copy = {
            let cp = self.tmp.cp_file.as_mut().ok_or(Error::Generic)?;
            set_pos(cp, cp_pos)?;
            cp.read_exact(&mut origin).is_ok() && le_u32(&origin) == blockindex
        };

        if !existing_copy {
            cpindex = self.tmp.cp_size;
            let new_cp_pos = cpindex as u64 * (BLOCK_SIZE as u64 + 4);
            let mut block = [0u8; BLOCK_SIZE];
            put_u32(&mut block[..4], self.tmp.new_unused_blockhead);
            {
                let cp = self.tmp.cp_file.as_mut().ok_or(Error::Generic)?;
                set_pos(cp, new_cp_pos)?;
                let mut raw = [0u8; 4];
                put_u32(&mut raw, blockindex);
                cp.write_all(&raw).map_err(Error::from)?;
                cp.write_all(&block).map_err(Error::from)?;
            }
            {
                let main = self.file.as_mut().ok_or(Error::NotMounted)?;
                set_pos(main, pos)?;
                let mut raw = [0u8; 4];
                put_u32(&mut raw, cpindex);
                main.write_all(&raw).map_err(Error::from)?;
            }
            self.tmp.cp_size += 1;
            self.tmp.new_unused_blockhead = blockindex;
            return Ok(());
        }

        let cp = self.tmp.cp_file.as_mut().ok_or(Error::Generic)?;
        set_pos(cp, cp_pos + 8)?;
        let mut raw = [0u8; 4];
        put_u32(&mut raw, self.tmp.new_unused_blockhead);
        cp.write_all(&raw).map_err(Error::from)?;
        self.tmp.new_unused_blockhead = blockindex;
        Ok(())
    }

    pub(crate) fn genblockindex(&mut self) -> Result<u32> {
        if self.tmp.new_unused_blockhead > 0 {
            let blockindex = self.tmp.new_unused_blockhead;
            let mut block = [0u8; BLOCK_SIZE];
            self.readblock(blockindex, &mut block)?;
            self.tmp.new_unused_blockhead = le_u32(&block[4..8]);
            return Ok(blockindex);
        }

        let blockindex = self.tmp.new_total_blocksize;
        let addindex = blockindex - self.tmp.total_blocksize;
        let pos = addindex as u64 * (BLOCK_SIZE as u64 + 4);
        let add = self.tmp.add_file.as_mut().ok_or(Error::Generic)?;
        set_pos(add, pos)?;
        let mut raw = [0u8; 4];
        put_u32(&mut raw, blockindex);
        add.write_all(&raw).map_err(Error::from)?;
        add.write_all(&[0u8; BLOCK_SIZE]).map_err(Error::from)?;
        self.tmp.new_total_blocksize += 1;
        Ok(blockindex)
    }

    pub(crate) fn read_directory_meta(&mut self, blockindex: u32) -> Result<DirectoryMeta> {
        let mut block = [0u8; BLOCK_SIZE];
        self.readblock(blockindex, &mut block)?;
        Ok(DirectoryMeta {
            stop_blockindex: le_u32(&block[BLOCK_STOP_BLOCKINDEX..BLOCK_STOP_BLOCKINDEX + 4]),
            offset: le_u16(&block[BLOCK_OFFSET..BLOCK_OFFSET + 2]),
        })
    }

    pub(crate) fn find_path_blockindex(
        &mut self,
        dir_blockindex: u32,
        pathname: &str,
    ) -> Result<Option<u32>> {
        let entry = self.find_entry(dir_blockindex, pathname)?;
        match entry {
            Some(found) if !found.is_file && found.start_blockindex > 0 => Ok(Some(found.start_blockindex)),
            _ => Ok(None),
        }
    }

    pub(crate) fn find_entry(
        &mut self,
        dir_blockindex: u32,
        name: &str,
    ) -> Result<Option<EntryLocation>> {
        let mut block = [0u8; BLOCK_SIZE];
        self.readblock(dir_blockindex, &mut block)?;
        let meta = DirectoryMeta {
            stop_blockindex: le_u32(&block[BLOCK_STOP_BLOCKINDEX..BLOCK_STOP_BLOCKINDEX + 4]),
            offset: le_u16(&block[BLOCK_OFFSET..BLOCK_OFFSET + 2]),
        };

        let mut index = dir_blockindex;
        loop {
            let mut k = BLOCK_HEAD;
            for _ in 0..BLOCK_ITEM_MAX_COUNT {
                let state = block[k];
                k += 1;
                let name_slice = &block[k..k + BLOCK_NAME_MAX_SIZE];
                k += BLOCK_NAME_MAX_SIZE;
                let start_blockindex = le_u32(&block[k..k + 4]);
                let stop_blockindex = le_u32(&block[k + 4..k + 8]);
                let file_offset = le_u16(&block[k + 8..k + 10]);
                let item_offset = (k + 10) as u16;

                if fixed_name_eq(name_slice, name) {
                    return Ok(Some(EntryLocation {
                        blockindex: index,
                        item_offset,
                        is_file: state & 0x01 == 1,
                        start_blockindex,
                        stop_blockindex,
                        file_offset,
                    }));
                }

                k += 10;
                if index == meta.stop_blockindex && k >= meta.offset as usize {
                    return Ok(None);
                }
            }

            let next = le_u32(&block[4..8]);
            if next == 0 {
                return Ok(None);
            }
            index = next;
            self.readblock(index, &mut block)?;
        }
    }

    pub(crate) fn append_dir_entry(
        &mut self,
        dir_head_index: u32,
        is_file: bool,
        name: &str,
        start_blockindex: u32,
        stop_blockindex: u32,
        file_offset: u16,
    ) -> Result<(u32, u16)> {
        let mut head_block = [0u8; BLOCK_SIZE];
        self.readblock(dir_head_index, &mut head_block)?;
        let tail_index = le_u32(&head_block[BLOCK_STOP_BLOCKINDEX..BLOCK_STOP_BLOCKINDEX + 4]);
        let tail_offset = le_u16(&head_block[BLOCK_OFFSET..BLOCK_OFFSET + 2]);

        if tail_index == dir_head_index {
            if tail_offset < BLOCK_SIZE as u16 {
                let mut k = tail_offset as usize;
                head_block[k] = if is_file { 1 } else { 0 };
                k += 1;
                copy_name_into(&mut head_block[k..k + BLOCK_NAME_MAX_SIZE], name);
                k += BLOCK_NAME_MAX_SIZE;
                put_u32(&mut head_block[k..k + 4], start_blockindex);
                k += 4;
                put_u32(&mut head_block[k..k + 4], stop_blockindex);
                k += 4;
                put_u16(&mut head_block[k..k + 2], file_offset);
                k += 2;
                put_u16(&mut head_block[BLOCK_OFFSET..BLOCK_OFFSET + 2], k as u16);
                self.writeblock(dir_head_index, &head_block)?;
                return Ok((dir_head_index, k as u16));
            }

            let new_blockindex = self.genblockindex()?;
            let mut new_block = [0u8; BLOCK_SIZE];
            put_u32(&mut new_block[8..12], dir_head_index);
            let mut k = BLOCK_HEAD;
            new_block[k] = if is_file { 1 } else { 0 };
            k += 1;
            copy_name_into(&mut new_block[k..k + BLOCK_NAME_MAX_SIZE], name);
            k += BLOCK_NAME_MAX_SIZE;
            put_u32(&mut new_block[k..k + 4], start_blockindex);
            k += 4;
            put_u32(&mut new_block[k..k + 4], stop_blockindex);
            k += 4;
            put_u16(&mut new_block[k..k + 2], file_offset);
            k += 2;
            put_u32(&mut head_block[4..8], new_blockindex);
            put_u32(
                &mut head_block[BLOCK_STOP_BLOCKINDEX..BLOCK_STOP_BLOCKINDEX + 4],
                new_blockindex,
            );
            put_u16(&mut head_block[BLOCK_OFFSET..BLOCK_OFFSET + 2], k as u16);
            self.writeblock(dir_head_index, &head_block)?;
            self.writeblock(new_blockindex, &new_block)?;
            return Ok((new_blockindex, k as u16));
        }

        let mut tail_block = [0u8; BLOCK_SIZE];
        self.readblock(tail_index, &mut tail_block)?;

        if tail_offset < BLOCK_SIZE as u16 {
            let mut k = tail_offset as usize;
            tail_block[k] = if is_file { 1 } else { 0 };
            k += 1;
            copy_name_into(&mut tail_block[k..k + BLOCK_NAME_MAX_SIZE], name);
            k += BLOCK_NAME_MAX_SIZE;
            put_u32(&mut tail_block[k..k + 4], start_blockindex);
            k += 4;
            put_u32(&mut tail_block[k..k + 4], stop_blockindex);
            k += 4;
            put_u16(&mut tail_block[k..k + 2], file_offset);
            k += 2;
            put_u16(&mut head_block[BLOCK_OFFSET..BLOCK_OFFSET + 2], k as u16);
            self.writeblock(tail_index, &tail_block)?;
            self.writeblock(dir_head_index, &head_block)?;
            return Ok((tail_index, k as u16));
        }

        let new_blockindex = self.genblockindex()?;
        let mut new_block = [0u8; BLOCK_SIZE];
        put_u32(&mut new_block[8..12], tail_index);
        let mut k = BLOCK_HEAD;
        new_block[k] = if is_file { 1 } else { 0 };
        k += 1;
        copy_name_into(&mut new_block[k..k + BLOCK_NAME_MAX_SIZE], name);
        k += BLOCK_NAME_MAX_SIZE;
        put_u32(&mut new_block[k..k + 4], start_blockindex);
        k += 4;
        put_u32(&mut new_block[k..k + 4], stop_blockindex);
        k += 4;
        put_u16(&mut new_block[k..k + 2], file_offset);
        k += 2;
        put_u32(&mut tail_block[4..8], new_blockindex);
        put_u32(
            &mut head_block[BLOCK_STOP_BLOCKINDEX..BLOCK_STOP_BLOCKINDEX + 4],
            new_blockindex,
        );
        put_u16(&mut head_block[BLOCK_OFFSET..BLOCK_OFFSET + 2], k as u16);
        self.writeblock(tail_index, &tail_block)?;
        self.writeblock(dir_head_index, &head_block)?;
        self.writeblock(new_blockindex, &new_block)?;
        Ok((new_blockindex, k as u16))
    }

    pub(crate) fn update_entry_name(&mut self, entry: &EntryLocation, new_name: &str) -> Result<()> {
        let mut block = [0u8; BLOCK_SIZE];
        self.readblock(entry.blockindex, &mut block)?;
        let start = entry.item_offset as usize - 24;
        let end = start + BLOCK_NAME_MAX_SIZE;
        copy_name_into(&mut block[start..end], new_name);
        self.writeblock(entry.blockindex, &block)
    }

    pub(crate) fn update_entry_parent(
        &mut self,
        entry: &EntryLocation,
        new_dir_head_index: u32,
    ) -> Result<()> {
        let mut block = [0u8; BLOCK_SIZE];
        self.readblock(entry.start_blockindex, &mut block)?;
        let parent_offset = BLOCK_HEAD + ENTRY_SIZE + 1 + BLOCK_NAME_MAX_SIZE;
        put_u32(&mut block[parent_offset..parent_offset + 4], new_dir_head_index);
        self.writeblock(entry.start_blockindex, &block)
    }

    pub(crate) fn update_entry_file_meta(
        &mut self,
        dir_blockindex: u32,
        dir_offset: u16,
        start_blockindex: u32,
        stop_blockindex: u32,
        file_offset: u16,
    ) -> Result<()> {
        let mut block = [0u8; BLOCK_SIZE];
        self.readblock(dir_blockindex, &mut block)?;
        let base = dir_offset as usize - 10;
        put_u32(&mut block[base..base + 4], start_blockindex);
        put_u32(&mut block[base + 4..base + 8], stop_blockindex);
        put_u16(&mut block[base + 8..base + 10], file_offset);
        self.writeblock(dir_blockindex, &block)
    }

    pub(crate) fn free_file_chain(&mut self, start_blockindex: u32, stop_blockindex: u32) -> Result<()> {
        if start_blockindex == 0 {
            return Ok(());
        }
        let mut stop_block = [0u8; BLOCK_SIZE];
        self.readblock(stop_blockindex, &mut stop_block)?;
        put_u32(&mut stop_block[4..8], self.tmp.new_unused_blockhead);
        self.tmp.new_unused_blockhead = start_blockindex;
        self.writeblock(stop_blockindex, &stop_block)
    }

    pub(crate) fn file_length_from_meta(
        &mut self,
        start_blockindex: u32,
        stop_blockindex: u32,
        file_offset: u16,
    ) -> Result<u64> {
        if start_blockindex == 0 {
            return Ok(0);
        }
        let mut total = 0u64;
        let mut index = start_blockindex;
        let mut block = [0u8; BLOCK_SIZE];
        loop {
            if index == stop_blockindex {
                total += (file_offset as usize - BLOCK_HEAD) as u64;
                return Ok(total);
            }
            self.readblock(index, &mut block)?;
            total += (BLOCK_SIZE - BLOCK_HEAD) as u64;
            index = le_u32(&block[4..8]);
            if index == 0 {
                return Ok(total);
            }
        }
    }

    pub(crate) fn remove_entry_from_directory(
        &mut self,
        dir_head_index: u32,
        entry: &EntryLocation,
    ) -> Result<()> {
        let mut head_block = [0u8; BLOCK_SIZE];
        self.readblock(dir_head_index, &mut head_block)?;
        let stop_blockindex = le_u32(&head_block[BLOCK_STOP_BLOCKINDEX..BLOCK_STOP_BLOCKINDEX + 4]);
        let mut offset = le_u16(&head_block[BLOCK_OFFSET..BLOCK_OFFSET + 2]);

        let mut stop_block = [0u8; BLOCK_SIZE];
        if stop_blockindex == dir_head_index {
            stop_block.copy_from_slice(&head_block);
        } else {
            self.readblock(stop_blockindex, &mut stop_block)?;
        }

        if entry.blockindex != stop_blockindex || entry.item_offset != offset {
            let src_start = offset as usize - ENTRY_SIZE;
            let src_end = offset as usize;
            let dst_start = entry.item_offset as usize - ENTRY_SIZE;
            let dst_end = entry.item_offset as usize;
            let moved = stop_block[src_start..src_end].to_vec();
            if entry.blockindex == dir_head_index {
                head_block[dst_start..dst_end].copy_from_slice(&moved);
                if stop_blockindex == dir_head_index {
                    stop_block.copy_from_slice(&head_block);
                }
            } else if entry.blockindex == stop_blockindex {
                stop_block[dst_start..dst_end].copy_from_slice(&moved);
            } else {
                let mut entry_block = [0u8; BLOCK_SIZE];
                self.readblock(entry.blockindex, &mut entry_block)?;
                entry_block[dst_start..dst_end].copy_from_slice(&moved);
                self.writeblock(entry.blockindex, &entry_block)?;
            }
        }

        offset -= ENTRY_SIZE as u16;
        put_u16(&mut head_block[BLOCK_OFFSET..BLOCK_OFFSET + 2], offset);
        if stop_blockindex == dir_head_index {
            stop_block.copy_from_slice(&head_block);
        }

        let mut prev_blockindex = 0u32;
        let mut prev_block = [0u8; BLOCK_SIZE];
        let mut removed_tail_block = false;
        if offset < ENTRY_SIZE as u16 {
            prev_blockindex = le_u32(&stop_block[8..12]);
            self.removeblock(stop_blockindex)?;
            self.readblock(prev_blockindex, &mut prev_block)?;
            put_u32(&mut prev_block[4..8], 0);
            put_u32(
                &mut head_block[BLOCK_STOP_BLOCKINDEX..BLOCK_STOP_BLOCKINDEX + 4],
                prev_blockindex,
            );
            put_u16(&mut head_block[BLOCK_OFFSET..BLOCK_OFFSET + 2], BLOCK_SIZE as u16);
            removed_tail_block = true;
        }

        if removed_tail_block {
            self.writeblock(dir_head_index, &head_block)?;
            self.writeblock(prev_blockindex, &prev_block)?;
        } else {
            self.writeblock(dir_head_index, &head_block)?;
        }

        if !removed_tail_block && stop_blockindex != dir_head_index {
            self.writeblock(stop_blockindex, &stop_block)?;
        }

        Ok(())
    }

    pub(crate) fn create_dir_block(&mut self, parent_blockindex: u32) -> Result<u32> {
        let blockindex = self.genblockindex()?;
        let mut block = [0u8; BLOCK_SIZE];
        let mut k = BLOCK_HEAD;

        block[k] = 0;
        k += 1;
        copy_name_into(&mut block[k..k + BLOCK_NAME_MAX_SIZE], ".");
        k += BLOCK_NAME_MAX_SIZE;
        put_u32(&mut block[BLOCK_START_BLOCKINDEX..BLOCK_START_BLOCKINDEX + 4], blockindex);
        put_u32(&mut block[k + 4..k + 8], blockindex);
        k += 4;
        k += 4;
        put_u16(&mut block[k..k + 2], (BLOCK_HEAD + ENTRY_SIZE * 2) as u16);
        k += 2;

        block[k] = 0;
        k += 1;
        copy_name_into(&mut block[k..k + BLOCK_NAME_MAX_SIZE], "..");
        k += BLOCK_NAME_MAX_SIZE;
        put_u32(&mut block[k..k + 4], parent_blockindex);

        self.writeblock(blockindex, &block)?;
        Ok(blockindex)
    }

    pub(crate) fn locate_file_position(
        &mut self,
        start_blockindex: u32,
        stop_blockindex: u32,
        file_offset: u16,
        target: u64,
    ) -> Result<(u32, u16)> {
        if start_blockindex == 0 {
            return Ok((0, 0));
        }

        let mut remaining = target;
        let mut index = start_blockindex;
        let mut block = [0u8; BLOCK_SIZE];
        loop {
            let block_size = if index == stop_blockindex {
                (file_offset as usize - BLOCK_HEAD) as u64
            } else {
                (BLOCK_SIZE - BLOCK_HEAD) as u64
            };

            if remaining < block_size {
                return Ok((index, BLOCK_HEAD as u16 + remaining as u16));
            }

            if remaining == block_size {
                if index == stop_blockindex {
                    return Ok((stop_blockindex, file_offset));
                }
                self.readblock(index, &mut block)?;
                let next = le_u32(&block[4..8]);
                return Ok((next, BLOCK_HEAD as u16));
            }

            remaining -= block_size;
            if index == stop_blockindex {
                return Ok((stop_blockindex, file_offset));
            }

            self.readblock(index, &mut block)?;
            index = le_u32(&block[4..8]);
            if index == 0 {
                return Ok((stop_blockindex, file_offset));
            }
        }
    }
}
