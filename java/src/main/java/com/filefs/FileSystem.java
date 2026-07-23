package com.filefs;

import java.io.EOFException;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;

public final class FileSystem implements AutoCloseable {
    private Path imagePath;
    private Path journalPath;
    private RandomAccessFile fp;

    private final Types.TxState tmp = new Types.TxState();

    private String pwd = "";
    private int pwdBlockindex;
    private String pwdTmp = "";

    public static void mkfs(Path path) throws IOException {
        try (RandomAccessFile file = new RandomAccessFile(path.toFile(), "rw")) {
            file.setLength(0L);

            byte[] block = new byte[Types.BLOCK_SIZE];
            System.arraycopy(Types.MAGIC, 0, block, 0, Types.MAGIC.length);
            Util.u32ToB4(2, block, 4);
            file.write(block);

            Arrays.fill(block, (byte) 0);
            int k = Types.BLOCK_HEAD;

            block[k] = 0;
            k++;
            Util.copyNameInto(block, k, ".");
            k += Types.BLOCK_NAME_MAX_SIZE;
            Util.u32ToB4(Types.ROOT_BLOCKINDEX, block, k);
            k += 4;
            Util.u32ToB4(Types.ROOT_BLOCKINDEX, block, k);
            k += 4;
            Util.u16ToB2(Types.BLOCK_HEAD + 2 * Types.ENTRY_SIZE, block, k);
            k += 2;

            block[k] = 0;
            k++;
            Util.copyNameInto(block, k, "..");

            file.write(block);
            Util.flush(file);
        }

        Files.deleteIfExists(Util.journalPathFor(path));
    }

    public void mount(Path path) throws IOException {
        RandomAccessFile newFile = new RandomAccessFile(path.toFile(), "rw");
        try {
            byte[] block0 = new byte[Types.BLOCK_SIZE];
            newFile.readFully(block0);
            if (!Arrays.equals(Arrays.copyOf(block0, 4), Types.MAGIC)) {
                throw new IOException("invalid FileFS magic");
            }
            if (Util.b4ToU32(block0, 4) < 2) {
                throw new IOException("invalid FileFS block count");
            }

            byte[] block1 = new byte[Types.BLOCK_SIZE];
            newFile.readFully(block1);
            if (block1[Types.BLOCK_HEAD] != 0
                || !".".equals(Util.cstrFromFixed(block1, Types.BLOCK_HEAD + 1, Types.BLOCK_NAME_MAX_SIZE))) {
                throw new IOException("invalid root directory");
            }
            int dotdot = Types.BLOCK_HEAD + Types.ENTRY_SIZE;
            if (block1[dotdot] != 0
                || !"..".equals(Util.cstrFromFixed(block1, dotdot + 1, Types.BLOCK_NAME_MAX_SIZE))) {
                throw new IOException("invalid root parent entry");
            }

            umount();
            fp = newFile;
            imagePath = path;
            journalPath = Util.journalPathFor(path);
            pwd = "/";
            pwdBlockindex = Types.ROOT_BLOCKINDEX;
            pwdTmp = "";
            applyJournal();
        } catch (IOException e) {
            newFile.close();
            throw e;
        }
    }

    public void umount() {
        tryClose(fp);
        fp = null;
        imagePath = null;

        if (journalPath != null) {
            tryDelete(journalPath);
            journalPath = null;
        }

        tmpStop();
        tmp.pwd = "";
        tmp.pwdBlockindex = 0;
        tmp.totalBlocksize = 0;
        tmp.unusedBlockhead = 0;
        tmp.newTotalBlocksize = 0;
        tmp.newUnusedBlockhead = 0;

        pwd = "";
        pwdBlockindex = 0;
        pwdTmp = "";
    }

    public boolean isMounted() {
        return fp != null;
    }

    public FileHandle open(String path, String mode) {
        requireMounted();
        if (path == null || path.isEmpty() || mode == null || mode.isEmpty()) {
            throw new FileFsException("path and mode are required");
        }

        int modeCode = switch (mode) {
            case "r" -> 0;
            case "w" -> 1;
            case "a" -> 2;
            case "r+" -> 3;
            case "w+" -> 4;
            case "a+" -> 5;
            default -> -1;
        };
        if (modeCode < 0) {
            throw new FileFsException("unsupported mode: " + mode);
        }

        int blockindex;
        int start;
        if (path.charAt(0) == '/') {
            blockindex = Types.ROOT_BLOCKINDEX;
            start = 1;
        } else {
            blockindex = currentPwdBlockindex();
            start = 0;
        }

        StringBuilder part = new StringBuilder();
        for (int i = start; i < path.length(); i++) {
            char ch = path.charAt(i);
            if (ch == '/') {
                if (part.isEmpty()) {
                    continue;
                }
                String name = part.toString();
                part.setLength(0);
                try {
                    int next = findPathBlockindex(blockindex, name);
                    if (next < 1) {
                        throw new FileFsException("directory not found: " + path);
                    }
                    blockindex = next;
                } catch (IOException e) {
                    throw new FileFsException("open failed for " + path, e);
                }
                continue;
            }
            part.append(ch);
            if (part.length() > Types.BLOCK_NAME_MAX_SIZE) {
                throw new FileFsException("name exceeds 14 bytes: " + path);
            }
        }
        if (part.isEmpty()) {
            throw new FileFsException("invalid file path: " + path);
        }
        String lastname = part.toString();
        if (".".equals(lastname) || "..".equals(lastname)) {
            throw new FileFsException("invalid file name: " + path);
        }

        try {
            FileHandle handle = switch (modeCode) {
                case 0, 3 -> doFopenR(lastname, modeCode, blockindex);
                case 1, 4 -> doFopenW(lastname, modeCode, blockindex);
                case 2, 5 -> doFopenA(lastname, modeCode, blockindex);
                default -> null;
            };
            if (handle == null) {
                throw new FileFsException("open failed: " + path);
            }
            return handle;
        } catch (IOException e) {
            throw new FileFsException("open failed: " + path, e);
        }
    }

    public int read(FileHandle handle, byte[] buf, int off, int len) {
        requireMounted();
        if (handle == null || !handle.open || buf == null || len <= 0 || off < 0 || off + len > buf.length) {
            return 0;
        }
        if (handle.mode == 1 || handle.mode == 2) {
            return 0;
        }
        if (handle.posBlockindex == 0) {
            return 0;
        }

        try {
            int k = 0;
            byte[] block = new byte[Types.BLOCK_SIZE];
            int blockindex = handle.posBlockindex;

            while (true) {
                if (!readblock(blockindex, block)) {
                    return 0;
                }
                int nextindex = Util.b4ToU32(block, 4);

                if (handle.posOffset == Types.BLOCK_SIZE) {
                    handle.posBlockindex = blockindex;
                    handle.posOffset = Types.BLOCK_HEAD;
                }

                if (blockindex == handle.fileStopBlockindex) {
                    int n = handle.fileOffset - handle.posOffset;
                    if (n <= 0) {
                        return k;
                    }
                    if (len - k < n) {
                        n = len - k;
                    }
                    System.arraycopy(block, handle.posOffset, buf, off + k, n);
                    k += n;
                    handle.posBlockindex = blockindex;
                    handle.posOffset += n;
                    handle.pos += n;
                    return k;
                }

                int n = Types.BLOCK_SIZE - handle.posOffset;
                if (n <= 0) {
                    return k;
                }
                if (len - k < n) {
                    n = len - k;
                }
                System.arraycopy(block, handle.posOffset, buf, off + k, n);
                k += n;
                handle.posBlockindex = blockindex;
                handle.posOffset += n;
                handle.pos += n;
                if (k >= len) {
                    return k;
                }

                blockindex = nextindex;
                if (nextindex == 0) {
                    return k;
                }
            }
        } catch (IOException e) {
            throw new FileFsException("read failed", e);
        }
    }

    public int write(FileHandle handle, byte[] buf, int off, int len) {
        requireMounted();
        if (handle == null || !handle.open || buf == null || len <= 0 || off < 0 || off + len > buf.length) {
            return 0;
        }
        if (handle.mode == 0) {
            return 0;
        }

        try {
            if (tmp.state == Types.TXN_NONE && !tmpStart(Types.TXN_AUTO)) {
                return 0;
            }

            int cut = 0;
            byte[] newBlock = new byte[Types.BLOCK_SIZE];
            byte[] posBlock = new byte[Types.BLOCK_SIZE];
            byte[] dirBlock = new byte[Types.BLOCK_SIZE];
            int nextBlockindex;

            if (handle.posBlockindex == 0) {
                int newBlockindex = genblockindex();
                if (newBlockindex == 0) {
                    if (tmp.state == Types.TXN_AUTO) {
                        tmpStop();
                    }
                    return 0;
                }
                Arrays.fill(posBlock, (byte) 0);
                if (!writeblock(newBlockindex, posBlock)) {
                    if (tmp.state == Types.TXN_AUTO) {
                        tmpStop();
                    }
                    return 0;
                }
                if (!readblock(handle.dirBlockindex, dirBlock)) {
                    if (tmp.state == Types.TXN_AUTO) {
                        tmpStop();
                    }
                    return 0;
                }
                Util.u32ToB4(newBlockindex, dirBlock, handle.dirOffset - 10);
                Util.u32ToB4(newBlockindex, dirBlock, handle.dirOffset - 6);
                Util.u16ToB2(Types.BLOCK_HEAD, dirBlock, handle.dirOffset - 2);
                handle.fileStartBlockindex = newBlockindex;
                handle.fileStopBlockindex = newBlockindex;
                handle.fileOffset = 0;
                handle.posBlockindex = newBlockindex;
                handle.posOffset = Types.BLOCK_HEAD;
                handle.pos = 0L;
                if (!writeblock(handle.dirBlockindex, dirBlock)) {
                    if (tmp.state == Types.TXN_AUTO) {
                        tmpStop();
                    }
                    return 0;
                }
                nextBlockindex = 0;
            } else {
                if (!readblock(handle.posBlockindex, posBlock)) {
                    if (tmp.state == Types.TXN_AUTO) {
                        tmpStop();
                    }
                    return 0;
                }
                nextBlockindex = Util.b4ToU32(posBlock, 4);
            }

            while (true) {
                if (handle.posOffset == Types.BLOCK_SIZE) {
                    if (nextBlockindex == 0) {
                        int newBlockindex = genblockindex();
                        if (newBlockindex == 0) {
                            if (tmp.state == Types.TXN_AUTO) {
                                tmpStop();
                            }
                            return 0;
                        }
                        Arrays.fill(newBlock, (byte) 0);
                        Util.u32ToB4(handle.posBlockindex, newBlock, 8);
                        Util.u32ToB4(newBlockindex, posBlock, 4);
                        if (!writeblock(handle.posBlockindex, posBlock)) {
                            if (tmp.state == Types.TXN_AUTO) {
                                tmpStop();
                            }
                            return 0;
                        }
                        handle.posBlockindex = newBlockindex;
                        handle.posOffset = Types.BLOCK_HEAD;
                        System.arraycopy(newBlock, 0, posBlock, 0, Types.BLOCK_SIZE);
                        nextBlockindex = 0;
                    } else {
                        if (!readblock(nextBlockindex, posBlock)) {
                            if (tmp.state == Types.TXN_AUTO) {
                                tmpStop();
                            }
                            return 0;
                        }
                        nextBlockindex = Util.b4ToU32(posBlock, 4);
                        handle.posBlockindex = nextBlockindex;
                        handle.posOffset = Types.BLOCK_HEAD;
                    }
                }

                int avail = Types.BLOCK_SIZE - handle.posOffset;
                int n = Math.min(len - cut, avail);
                System.arraycopy(buf, off + cut, posBlock, handle.posOffset, n);
                cut += n;
                if (!writeblock(handle.posBlockindex, posBlock)) {
                    if (tmp.state == Types.TXN_AUTO) {
                        tmpStop();
                    }
                    return 0;
                }
                handle.posOffset += n;
                handle.pos += n;

                boolean grew = handle.posBlockindex > handle.fileStopBlockindex
                    || (handle.posBlockindex == handle.fileStopBlockindex && handle.posOffset > handle.fileOffset);
                if (grew) {
                    if (!readblock(handle.dirBlockindex, dirBlock)) {
                        if (tmp.state == Types.TXN_AUTO) {
                            tmpStop();
                        }
                        return 0;
                    }
                    handle.fileStopBlockindex = handle.posBlockindex;
                    handle.fileOffset = handle.posOffset;
                    Util.u32ToB4(handle.posBlockindex, dirBlock, handle.dirOffset - 6);
                    Util.u16ToB2(handle.posOffset, dirBlock, handle.dirOffset - 2);
                    if (!writeblock(handle.dirBlockindex, dirBlock)) {
                        if (tmp.state == Types.TXN_AUTO) {
                            tmpStop();
                        }
                        return 0;
                    }
                }

                if (cut >= len) {
                    if (tmp.state == Types.TXN_AUTO && !commit()) {
                        return 0;
                    }
                    return len;
                }
            }
        } catch (IOException e) {
            throw new FileFsException("write failed", e);
        }
    }

    public void close(FileHandle handle) {
        if (handle != null) {
            handle.close();
        }
    }

    public boolean seek(FileHandle handle, long offset, SeekWhence whence) {
        requireMounted();
        if (handle == null || !handle.open || whence == null) {
            return false;
        }
        if (handle.posBlockindex == 0) {
            return false;
        }

        try {
            byte[] block = new byte[Types.BLOCK_SIZE];

            if (whence == SeekWhence.CUR) {
                if (offset == 0) {
                    return true;
                }
                if (offset > 0) {
                    int blockindex = handle.posBlockindex;
                    long newOffset = offset;
                    int posOffset = handle.posOffset;
                    while (true) {
                        int blocksize = blockindex == handle.fileStopBlockindex ? handle.fileOffset : Types.BLOCK_SIZE;
                        if (blockindex == handle.fileStopBlockindex) {
                            if (blocksize - posOffset >= newOffset) {
                                handle.posOffset += (int) newOffset;
                                handle.pos += newOffset;
                            } else {
                                handle.posOffset += blocksize - posOffset;
                                handle.pos += blocksize - posOffset;
                            }
                            return true;
                        }
                        handle.posOffset = Types.BLOCK_SIZE;
                        handle.pos += Types.BLOCK_SIZE - posOffset;
                        newOffset -= Types.BLOCK_SIZE - posOffset;
                        posOffset = Types.BLOCK_HEAD;

                        if (!readblock(blockindex, block)) {
                            return true;
                        }
                        int nextBlockindex = Util.b4ToU32(block, 8);
                        if (nextBlockindex == 0) {
                            return true;
                        }
                        blockindex = nextBlockindex;
                        handle.posBlockindex = blockindex;
                    }
                }

                int blockindex = handle.posBlockindex;
                long newOffset = -offset;
                int posOffset = handle.posOffset;
                while (true) {
                    if (posOffset - Types.BLOCK_HEAD >= newOffset) {
                        handle.posOffset -= (int) newOffset;
                        handle.pos -= newOffset;
                        return true;
                    }
                    handle.posOffset -= posOffset;
                    handle.pos -= posOffset;
                    newOffset -= posOffset;
                    posOffset = Types.BLOCK_SIZE;

                    if (!readblock(blockindex, block)) {
                        return true;
                    }
                    int prevBlockindex = Util.b4ToU32(block, 4);
                    if (prevBlockindex == 0) {
                        return true;
                    }
                    blockindex = prevBlockindex;
                    handle.posBlockindex = blockindex;
                }
            }

            if (whence == SeekWhence.END) {
                long pos = handle.pos - (handle.posOffset - Types.BLOCK_HEAD);
                int index = handle.posBlockindex;
                while (true) {
                    if (index == handle.fileStopBlockindex) {
                        pos += handle.fileOffset - Types.BLOCK_HEAD;
                        break;
                    }
                    if (!readblock(index, block)) {
                        return false;
                    }
                    pos += Types.BLOCK_SIZE - Types.BLOCK_HEAD;
                    index = Util.b4ToU32(block, 4);
                }
                handle.posBlockindex = handle.fileStopBlockindex;
                handle.posOffset = handle.fileOffset;
                handle.pos = pos;

                if (offset == 0) {
                    return true;
                }
                if (offset < 0) {
                    int blockindex = handle.posBlockindex;
                    long newOffset = -offset;
                    int posOffset = handle.posOffset;
                    while (true) {
                        if (posOffset - Types.BLOCK_HEAD >= newOffset) {
                            handle.posOffset -= (int) newOffset;
                            handle.pos -= newOffset;
                            return true;
                        }
                        handle.posOffset -= posOffset;
                        handle.pos -= posOffset;
                        newOffset -= posOffset;
                        posOffset = Types.BLOCK_SIZE;

                        if (!readblock(blockindex, block)) {
                            return true;
                        }
                        int prevBlockindex = Util.b4ToU32(block, 4);
                        if (prevBlockindex == 0) {
                            return true;
                        }
                        blockindex = prevBlockindex;
                        handle.posBlockindex = blockindex;
                    }
                }
                return false;
            }

            if (whence == SeekWhence.SET) {
                handle.posBlockindex = handle.fileStartBlockindex;
                handle.posOffset = Types.BLOCK_HEAD;
                handle.pos = 0L;
                if (offset == 0) {
                    return true;
                }
                if (offset > 0) {
                    int blockindex = handle.posBlockindex;
                    long newOffset = offset;
                    int posOffset = handle.posOffset;
                    while (true) {
                        int blocksize = blockindex == handle.fileStopBlockindex ? handle.fileOffset : Types.BLOCK_SIZE;
                        if (blockindex == handle.fileStopBlockindex) {
                            if (blocksize - posOffset >= newOffset) {
                                handle.posOffset += (int) newOffset;
                                handle.pos += newOffset;
                            } else {
                                handle.posOffset += blocksize - posOffset;
                                handle.pos += blocksize - posOffset;
                            }
                            return true;
                        }
                        handle.posOffset = Types.BLOCK_SIZE;
                        handle.pos += Types.BLOCK_SIZE - posOffset;
                        newOffset -= Types.BLOCK_SIZE - posOffset;
                        posOffset = Types.BLOCK_HEAD;

                        if (!readblock(blockindex, block)) {
                            return true;
                        }
                        int nextBlockindex = Util.b4ToU32(block, 8);
                        if (nextBlockindex == 0) {
                            return true;
                        }
                        blockindex = nextBlockindex;
                        handle.posBlockindex = blockindex;
                    }
                }
                return false;
            }

            return false;
        } catch (IOException e) {
            throw new FileFsException("seek failed", e);
        }
    }

    public long tell(FileHandle handle) {
        requireMounted();
        if (handle == null || !handle.open) {
            return 0L;
        }
        return handle.pos;
    }

    public void rewind(FileHandle handle) {
        seek(handle, 0L, SeekWhence.SET);
    }

    public boolean fileExists(String path) {
        return stat(path) == 1;
    }

    public boolean dirExists(String path) {
        return stat(path) == 2;
    }

    public void removeFile(String path) {
        int rc = removeCode(path);
        if (rc != 0) {
            throw new FileFsException("removeFile failed rc=" + rc + " path=" + path);
        }
    }

    public void rename(String from, String to) {
        int rc = renameCode(from, to);
        if (rc != 0) {
            throw new FileFsException("rename failed rc=" + rc + " from=" + from + " to=" + to);
        }
    }

    public void move(String from, String toDir) {
        int rc = moveCode(from, toDir);
        if (rc != 0) {
            throw new FileFsException("move failed rc=" + rc + " from=" + from + " to=" + toDir);
        }
    }

    public void copyFile(String from, String to) {
        int rc = copyCode(from, to);
        if (rc != 0) {
            throw new FileFsException("copyFile failed rc=" + rc + " from=" + from + " to=" + to);
        }
    }

    public void chdir(String path) {
        try {
            if (!chdirInternal(path)) {
                throw new FileFsException("chdir failed: " + path);
            }
        } catch (IOException e) {
            throw new FileFsException("chdir failed: " + path, e);
        }
    }

    public String getcwd() {
        return tmp.state == Types.TXN_NONE ? pwd : tmp.pwd;
    }

    public void mkdir(String path) {
        int rc = mkdirCode(path);
        if (rc != 0) {
            throw new FileFsException("mkdir failed rc=" + rc + " path=" + path);
        }
    }

    public void rmdir(String path) {
        int rc = rmdirCode(path);
        if (rc != 0) {
            throw new FileFsException("rmdir failed rc=" + rc + " path=" + path);
        }
    }

    public DirectoryHandle openDir(String path) {
        requireMounted();
        try {
            DirectoryHandle dir = doOpenDir(path);
            if (dir == null) {
                throw new FileFsException("openDir failed: " + path);
            }
            return dir;
        } catch (IOException e) {
            throw new FileFsException("openDir failed: " + path, e);
        }
    }

    public DirEntry readDir(DirectoryHandle dir) {
        requireMounted();
        if (dir == null || !dir.open) {
            return null;
        }

        byte[] block = dir.block;
        int k = Types.BLOCK_HEAD + dir.searchindex * Types.ENTRY_SIZE;
        if (dir.blockindex == dir.stopBlockindex && k + 1 >= dir.offset) {
            return null;
        }

        try {
            while (true) {
                if (dir.searchindex >= Types.BLOCK_ITEM_MAX_COUNT) {
                    int nextindex = Util.b4ToU32(block, 4);
                    if (nextindex == 0) {
                        return null;
                    }
                    if (!readblock(nextindex, dir.block)) {
                        return null;
                    }
                    block = dir.block;
                    dir.searchindex = 0;
                    dir.blockindex = nextindex;
                    k = Types.BLOCK_HEAD;
                    continue;
                }

                byte state = block[k];
                k++;
                FileType type = (state & 0x01) == 1 ? FileType.FILE : FileType.DIR;
                String name = Util.cstrFromFixed(block, k, Types.BLOCK_NAME_MAX_SIZE);
                if (".".equals(name)) {
                    int dirblockindex = Util.b4ToU32(block, k + Types.BLOCK_NAME_MAX_SIZE);
                    if (dirblockindex == Types.ROOT_BLOCKINDEX) {
                        type = FileType.ROOT;
                    }
                } else if ("..".equals(name)) {
                    int dirblockindex = Util.b4ToU32(block, k + Types.BLOCK_NAME_MAX_SIZE);
                    if (dirblockindex == 0) {
                        type = FileType.ROOT;
                    }
                }
                k += Types.BLOCK_NAME_MAX_SIZE + 10;
                dir.searchindex++;
                return new DirEntry(type, name);
            }
        } catch (IOException e) {
            throw new FileFsException("readDir failed", e);
        }
    }

    public void closeDir(DirectoryHandle dir) {
        if (dir != null) {
            dir.close();
        }
    }

    public boolean begin() {
        requireMounted();
        if (tmp.fpCp != null) {
            rollback();
        }
        try {
            return tmpStart(Types.TXN_MANUAL);
        } catch (IOException e) {
            throw new FileFsException("begin failed", e);
        }
    }

    public boolean commit() {
        requireMounted();
        if (tmp.fpCp == null) {
            return true;
        }

        String committedPwd = tmp.pwd;
        int committedPwdBlockindex = tmp.pwdBlockindex;
        try {
            try (RandomAccessFile journal = new RandomAccessFile(journalPath.toFile(), "rw")) {
                journal.setLength(0L);
                journal.write(0);

                byte[] block = new byte[Types.BLOCK_SIZE + 4];

                if (tmp.totalBlocksize != tmp.newTotalBlocksize || tmp.unusedBlockhead != tmp.newUnusedBlockhead) {
                    Arrays.fill(block, (byte) 0);
                    Util.u32ToB4(0, block, 0);
                    System.arraycopy(Types.MAGIC, 0, block, 4, Types.MAGIC.length);
                    Util.u32ToB4(tmp.newTotalBlocksize, block, 8);
                    Util.u32ToB4(tmp.newUnusedBlockhead, block, 12);
                    journal.write(block);
                }

                Util.rewind(tmp.fpCp);
                while (tryReadExact(tmp.fpCp, block, 0, block.length)) {
                    journal.write(block);
                }

                Util.rewind(tmp.fpAdd);
                while (tryReadExact(tmp.fpAdd, block, 0, block.length)) {
                    journal.write(block);
                }

                Util.rewind(journal);
                journal.write(0xFF);
                Util.flush(journal);
            }

            try (RandomAccessFile journal = new RandomAccessFile(journalPath.toFile(), "r")) {
                if (journal.read() != 0xFF) {
                    tmpStop();
                    return false;
                }

                byte[] block = new byte[Types.BLOCK_SIZE + 4];
                while (tryReadExact(journal, block, 0, block.length)) {
                    int blockindex = Util.b4ToU32(block, 0);
                    Util.setPos(fp, (long) blockindex * Types.BLOCK_SIZE);
                    fp.write(block, 4, Types.BLOCK_SIZE);
                }
            }

            Util.flush(fp);
            Files.deleteIfExists(journalPath);
            pwd = committedPwd;
            pwdBlockindex = committedPwdBlockindex;
            tmpStop();
            return true;
        } catch (IOException e) {
            tmpStop();
            throw new FileFsException("commit failed", e);
        }
    }

    public void rollback() {
        if (!isMounted()) {
            return;
        }
        if (journalPath != null) {
            tryDelete(journalPath);
        }
        if (tmp.fpCp == null) {
            return;
        }
        tmpStop();
    }

    @Override
    public void close() {
        umount();
    }

    private FileHandle doFopenR(String lastname, int mode, int blockHeadIndex) throws IOException {
        byte[] block = new byte[Types.BLOCK_SIZE];
        if (!readblock(blockHeadIndex, block)) {
            return null;
        }
        int stopBlockindex = Util.b4ToU32(block, Types.BLOCK_HEAD + 1 + 14 + 4);
        int offset = Util.b2ToU16(block, Types.BLOCK_HEAD + 1 + 14 + 4 + 4);

        boolean found = false;
        int dirBlockindex = 0;
        int dirOffset = 0;
        int index = blockHeadIndex;

        while (true) {
            int k = Types.BLOCK_HEAD;
            for (int i = 0; i < Types.BLOCK_ITEM_MAX_COUNT; i++) {
                byte state = block[k];
                k++;
                String name = Util.cstrFromFixed(block, k, Types.BLOCK_NAME_MAX_SIZE);
                k += Types.BLOCK_NAME_MAX_SIZE;
                if (!lastname.equals(name)) {
                    k += 10;
                    if (index == stopBlockindex && k + 1 >= offset) {
                        return null;
                    }
                    continue;
                }
                if ((state & 0x01) == 0) {
                    return null;
                }
                dirBlockindex = index;
                dirOffset = k + 10;
                found = true;
                break;
            }
            if (found) {
                break;
            }
            index = Util.b4ToU32(block, 4);
            if (index == 0) {
                return null;
            }
            if (!readblock(index, block)) {
                return null;
            }
        }

        FileHandle handle = new FileHandle();
        handle.mode = mode;
        handle.dirBlockindex = dirBlockindex;
        handle.dirOffset = dirOffset;
        handle.fileStartBlockindex = Util.b4ToU32(block, dirOffset - 10);
        handle.fileStopBlockindex = Util.b4ToU32(block, dirOffset - 6);
        handle.fileOffset = Util.b2ToU16(block, dirOffset - 2);
        handle.posBlockindex = handle.fileStartBlockindex;
        handle.posOffset = Types.BLOCK_HEAD;
        handle.pos = 0L;
        return handle;
    }

    private boolean doFopenCreatefileitem(String lastname, int orgStartBlockindex, int orgStopBlockindex, int orgOffset,
                                          byte[] dirBlock, IntBox dirBlockindex, IntBox dirOffset) throws IOException {
        Types.BlockArray[] ba = {new Types.BlockArray(), new Types.BlockArray()};

        if (!readblock(orgStartBlockindex, ba[0].block)) {
            return false;
        }
        ba[0].blockindex = orgStartBlockindex;
        ba[0].active = true;
        byte[] blockStart = ba[0].block;
        int blockStartIndex = ba[0].blockindex;

        byte[] blockStop;
        int blockStopIndex;
        if (orgStopBlockindex == orgStartBlockindex) {
            blockStop = blockStart;
            blockStopIndex = blockStartIndex;
        } else {
            if (!readblock(orgStopBlockindex, ba[1].block)) {
                return false;
            }
            ba[1].blockindex = orgStopBlockindex;
            ba[1].active = true;
            blockStop = ba[1].block;
            blockStopIndex = ba[1].blockindex;
        }

        boolean auto = tmp.state == Types.TXN_NONE;
        if (auto && !tmpStart(Types.TXN_AUTO)) {
            return false;
        }

        if (orgOffset < Types.BLOCK_SIZE) {
            int k = orgOffset;
            blockStop[k] = 1;
            k++;
            Util.copyNameInto(blockStop, k, lastname);
            k += Types.BLOCK_NAME_MAX_SIZE;
            k += 4;
            k += 4;
            k += 2;
            int newOffset = k;
            Util.u16ToB2(newOffset, blockStart, Types.BLOCK_OFFSET);

            for (Types.BlockArray blockArray : ba) {
                if (blockArray.active && !writeblock(blockArray.blockindex, blockArray.block)) {
                    if (auto) {
                        tmpStop();
                    }
                    return false;
                }
            }
            if (auto && !commit()) {
                return false;
            }
            System.arraycopy(blockStop, 0, dirBlock, 0, Types.BLOCK_SIZE);
            dirBlockindex.value = blockStopIndex;
            dirOffset.value = newOffset;
            return true;
        }

        int blockindex2 = genblockindex();
        if (blockindex2 == 0) {
            if (auto) {
                tmpStop();
            }
            return false;
        }
        byte[] block2 = new byte[Types.BLOCK_SIZE];
        int k = 8;
        Util.u32ToB4(orgStopBlockindex, block2, k);
        k += 4;
        block2[k] = 1;
        k++;
        Util.copyNameInto(block2, k, lastname);
        k += Types.BLOCK_NAME_MAX_SIZE;
        k += 4;
        k += 4;
        k += 2;
        int newOffset = k;
        Util.u16ToB2(newOffset, blockStart, Types.BLOCK_OFFSET);
        Util.u32ToB4(blockindex2, blockStart, Types.BLOCK_STOP_BLOCKINDEX);
        Util.u32ToB4(blockindex2, blockStop, 4);

        for (Types.BlockArray blockArray : ba) {
            if (blockArray.active && !writeblock(blockArray.blockindex, blockArray.block)) {
                if (auto) {
                    tmpStop();
                }
                return false;
            }
        }
        if (!writeblock(blockindex2, block2)) {
            if (auto) {
                tmpStop();
            }
            return false;
        }
        if (auto && !commit()) {
            return false;
        }
        System.arraycopy(block2, 0, dirBlock, 0, Types.BLOCK_SIZE);
        dirBlockindex.value = blockindex2;
        dirOffset.value = newOffset;
        return true;
    }

    private boolean doFopenCleanfilecontent(byte[] dirBlock, int dirBlockindex, int dirOffset) throws IOException {
        int fileStart = Util.b4ToU32(dirBlock, dirOffset - 10);
        int fileStop = Util.b4ToU32(dirBlock, dirOffset - 6);
        if (fileStart == 0) {
            return true;
        }

        boolean auto = tmp.state == Types.TXN_NONE;
        if (auto && !tmpStart(Types.TXN_AUTO)) {
            return false;
        }

        byte[] fileBlockStop = new byte[Types.BLOCK_SIZE];
        if (!readblock(fileStop, fileBlockStop)) {
            if (auto) {
                tmpStop();
            }
            return false;
        }
        Util.u32ToB4(tmp.newUnusedBlockhead, fileBlockStop, 4);
        tmp.newUnusedBlockhead = fileStart;

        for (int i = 0; i < 10; i++) {
            dirBlock[dirOffset - 10 + i] = 0;
        }

        if (!writeblock(dirBlockindex, dirBlock) || !writeblock(fileStop, fileBlockStop)) {
            if (auto) {
                tmpStop();
            }
            return false;
        }
        if (auto && !commit()) {
            return false;
        }
        return true;
    }

    private FileHandle doFopenW(String lastname, int mode, int blockHeadIndex) throws IOException {
        byte[] block = new byte[Types.BLOCK_SIZE];
        if (!readblock(blockHeadIndex, block)) {
            return null;
        }
        int stopBlockindex = Util.b4ToU32(block, Types.BLOCK_HEAD + 1 + 14 + 4);
        int offset = Util.b2ToU16(block, Types.BLOCK_HEAD + 1 + 14 + 8);

        boolean found = false;
        boolean dirExists = false;
        int dirBlockindex = 0;
        int dirOffset = 0;
        int index = blockHeadIndex;

        while (true) {
            int k = Types.BLOCK_HEAD;
            for (int i = 0; i < Types.BLOCK_ITEM_MAX_COUNT; i++) {
                byte state = block[k];
                k++;
                String name = Util.cstrFromFixed(block, k, Types.BLOCK_NAME_MAX_SIZE);
                k += Types.BLOCK_NAME_MAX_SIZE;
                if (!lastname.equals(name)) {
                    k += 10;
                    if (index == stopBlockindex && k + 1 >= offset) {
                        found = true;
                        break;
                    }
                    continue;
                }
                if ((state & 0x01) == 0) {
                    return null;
                }
                dirBlockindex = index;
                dirOffset = k + 10;
                dirExists = true;
                found = true;
                break;
            }
            if (found) {
                break;
            }
            index = Util.b4ToU32(block, 4);
            if (index == 0 || !readblock(index, block)) {
                return null;
            }
        }

        if (!dirExists) {
            IntBox blockindexBox = new IntBox(dirBlockindex);
            IntBox dirOffsetBox = new IntBox(dirOffset);
            if (!doFopenCreatefileitem(lastname, blockHeadIndex, stopBlockindex, offset, block, blockindexBox, dirOffsetBox)) {
                return null;
            }
            dirBlockindex = blockindexBox.value;
            dirOffset = dirOffsetBox.value;
        } else if (!doFopenCleanfilecontent(block, dirBlockindex, dirOffset)) {
            return null;
        }

        FileHandle handle = new FileHandle();
        handle.mode = mode;
        handle.dirBlockindex = dirBlockindex;
        handle.dirOffset = dirOffset;
        return handle;
    }

    private FileHandle doFopenA(String lastname, int mode, int blockHeadIndex) throws IOException {
        byte[] block = new byte[Types.BLOCK_SIZE];
        if (!readblock(blockHeadIndex, block)) {
            return null;
        }
        int stopBlockindex = Util.b4ToU32(block, Types.BLOCK_HEAD + 1 + 14 + 4);
        int offset = Util.b2ToU16(block, Types.BLOCK_HEAD + 1 + 14 + 8);

        boolean found = false;
        boolean dirExists = false;
        int dirBlockindex = 0;
        int dirOffset = 0;
        int index = blockHeadIndex;

        while (true) {
            int k = Types.BLOCK_HEAD;
            for (int i = 0; i < Types.BLOCK_ITEM_MAX_COUNT; i++) {
                byte state = block[k];
                k++;
                String name = Util.cstrFromFixed(block, k, Types.BLOCK_NAME_MAX_SIZE);
                k += Types.BLOCK_NAME_MAX_SIZE;
                if (!lastname.equals(name)) {
                    k += 10;
                    if (index == stopBlockindex && k + 1 >= offset) {
                        found = true;
                        break;
                    }
                    continue;
                }
                if ((state & 0x01) == 0) {
                    return null;
                }
                dirBlockindex = index;
                dirOffset = k + 10;
                dirExists = true;
                found = true;
                break;
            }
            if (found) {
                break;
            }
            index = Util.b4ToU32(block, 4);
            if (index == 0 || !readblock(index, block)) {
                return null;
            }
        }

        if (!dirExists) {
            IntBox blockindexBox = new IntBox(dirBlockindex);
            IntBox dirOffsetBox = new IntBox(dirOffset);
            if (!doFopenCreatefileitem(lastname, blockHeadIndex, stopBlockindex, offset, block, blockindexBox, dirOffsetBox)) {
                return null;
            }
            FileHandle handle = new FileHandle();
            handle.mode = mode;
            handle.dirBlockindex = blockindexBox.value;
            handle.dirOffset = dirOffsetBox.value;
            return handle;
        }

        int fileStart = Util.b4ToU32(block, dirOffset - 10);
        int fileStop = Util.b4ToU32(block, dirOffset - 6);
        int fileOffset = Util.b2ToU16(block, dirOffset - 2);
        long pos = 0L;
        index = fileStart;
        while (true) {
            if (index == fileStop) {
                pos += fileOffset - Types.BLOCK_HEAD;
                break;
            }
            if (!readblock(index, block)) {
                return null;
            }
            pos += Types.BLOCK_SIZE - Types.BLOCK_HEAD;
            index = Util.b4ToU32(block, 4);
        }

        FileHandle handle = new FileHandle();
        handle.mode = mode;
        handle.dirBlockindex = dirBlockindex;
        handle.dirOffset = dirOffset;
        handle.fileStartBlockindex = fileStart;
        handle.fileStopBlockindex = fileStop;
        handle.fileOffset = fileOffset;
        handle.posBlockindex = fileStop;
        handle.posOffset = fileOffset;
        handle.pos = pos;
        return handle;
    }

    private int stat(String name) {
        if (name == null || name.isEmpty() || !isMounted()) {
            return 0;
        }

        try {
            byte[] block = new byte[Types.BLOCK_SIZE];
            int blockindex;
            int start;
            if (name.charAt(0) == '/') {
                blockindex = Types.ROOT_BLOCKINDEX;
                start = 1;
            } else {
                blockindex = currentPwdBlockindex();
                start = 0;
            }

            StringBuilder part = new StringBuilder();
            for (int i = start; i < name.length(); i++) {
                char ch = name.charAt(i);
                if (ch == '/') {
                    if (part.isEmpty()) {
                        continue;
                    }
                    int next = findPathBlockindex(blockindex, part.toString());
                    if (next < 1) {
                        return 0;
                    }
                    blockindex = next;
                    part.setLength(0);
                    continue;
                }
                part.append(ch);
                if (part.length() > Types.BLOCK_NAME_MAX_SIZE) {
                    return 0;
                }
            }
            if (part.isEmpty()) {
                return 2;
            }
            String lastname = part.toString();

            if (!readblock(blockindex, block)) {
                return 0;
            }
            int stopBlockindex = Util.b4ToU32(block, Types.BLOCK_HEAD + 1 + 14 + 4);
            int offset = Util.b2ToU16(block, Types.BLOCK_HEAD + 1 + 14 + 8);

            int index = blockindex;
            while (true) {
                int k = Types.BLOCK_HEAD;
                for (int i = 0; i < Types.BLOCK_ITEM_MAX_COUNT; i++) {
                    byte state = block[k];
                    k++;
                    String entryName = Util.cstrFromFixed(block, k, Types.BLOCK_NAME_MAX_SIZE);
                    k += Types.BLOCK_NAME_MAX_SIZE;
                    if (!lastname.equals(entryName)) {
                        k += 10;
                        if (index == stopBlockindex && k + 1 >= offset) {
                            return 0;
                        }
                        continue;
                    }
                    return (state & 0x01) == 0 ? 2 : 1;
                }
                index = Util.b4ToU32(block, 4);
                if (index == 0 || !readblock(index, block)) {
                    return 0;
                }
            }
        } catch (IOException e) {
            throw new FileFsException("stat failed: " + name, e);
        }
    }

    private boolean chdirInternal(String pathname) throws IOException {
        requireMounted();
        int lenN = pathname == null ? 0 : pathname.length();
        int blockindex;
        int start;
        if (lenN > 0 && pathname.charAt(0) == '/') {
            blockindex = Types.ROOT_BLOCKINDEX;
            start = 1;
            if (!initPwdtmp("/")) {
                return false;
            }
        } else {
            blockindex = currentPwdBlockindex();
            if (!initPwdtmp(currentPwd())) {
                return false;
            }
            start = 0;
        }

        StringBuilder part = new StringBuilder();
        for (int i = start; i < lenN; i++) {
            char ch = pathname.charAt(i);
            if (ch == '/') {
                if (part.isEmpty()) {
                    continue;
                }
                int index = findPathBlockindex(blockindex, part.toString());
                if (index < 1) {
                    return false;
                }
                blockindex = index;
                if (!addToPwdtmp(lenN, part.toString())) {
                    return false;
                }
                part.setLength(0);
                continue;
            }
            part.append(ch);
            if (part.length() > Types.BLOCK_NAME_MAX_SIZE) {
                return false;
            }
        }
        if (!part.isEmpty()) {
            int index = findPathBlockindex(blockindex, part.toString());
            if (index < 1) {
                return false;
            }
            blockindex = index;
            if (!addToPwdtmp(lenN, part.toString())) {
                return false;
            }
        }

        if (tmp.state == Types.TXN_NONE) {
            pwd = pwdTmp;
            pwdBlockindex = blockindex;
        } else {
            tmp.pwd = pwdTmp;
            tmp.pwdBlockindex = blockindex;
        }
        return true;
    }

    private DirectoryHandle doOpenDir(String path) throws IOException {
        DirectoryHandle dir = new DirectoryHandle();
        int lenN = path == null ? 0 : path.length();
        int blockindex;
        int start;
        if (lenN > 0 && path.charAt(0) == '/') {
            blockindex = Types.ROOT_BLOCKINDEX;
            start = 1;
            if (!initPwdtmp("/")) {
                return null;
            }
        } else {
            blockindex = currentPwdBlockindex();
            if (!initPwdtmp(currentPwd())) {
                return null;
            }
            start = 0;
        }

        StringBuilder part = new StringBuilder();
        for (int i = start; i < lenN; i++) {
            char ch = path.charAt(i);
            if (ch == '/') {
                if (part.isEmpty()) {
                    continue;
                }
                int index = findPathBlockindex(blockindex, part.toString());
                if (index < 1) {
                    return null;
                }
                blockindex = index;
                if (!addToPwdtmp(lenN, part.toString())) {
                    return null;
                }
                part.setLength(0);
                continue;
            }
            part.append(ch);
            if (part.length() > Types.BLOCK_NAME_MAX_SIZE) {
                return null;
            }
        }
        if (!part.isEmpty()) {
            int index = findPathBlockindex(blockindex, part.toString());
            if (index < 1) {
                return null;
            }
            blockindex = index;
            if (!addToPwdtmp(lenN, part.toString())) {
                return null;
            }
        }

        if (!readblock(blockindex, dir.block)) {
            return null;
        }
        dir.stopBlockindex = Util.b4ToU32(dir.block, Types.BLOCK_HEAD + 1 + 14 + 4);
        dir.offset = Util.b2ToU16(dir.block, Types.BLOCK_HEAD + 1 + 14 + 8);
        dir.blockindex = blockindex;
        dir.searchindex = 0;
        dir.absolutePath = pwdTmp;
        return dir;
    }

    private boolean initPwdtmp(String value) {
        pwdTmp = value;
        return true;
    }

    private boolean addToPwdtmp(int pathsize, String value) {
        if (".".equals(value)) {
            return true;
        }
        if ("..".equals(value)) {
            for (int i = 1; i < pwdTmp.length(); i++) {
                if (pwdTmp.charAt(pwdTmp.length() - i - 1) == '/') {
                    pwdTmp = pwdTmp.substring(0, pwdTmp.length() - i);
                    return true;
                }
            }
            return false;
        }
        pwdTmp = pwdTmp + value + "/";
        return true;
    }

    private int mkdirCode(String pathname) {
        if (pathname == null || pathname.isEmpty() || !isMounted()) {
            return 1;
        }

        try {
            int blockindex;
            int start;
            if (pathname.charAt(0) == '/') {
                blockindex = Types.ROOT_BLOCKINDEX;
                start = 1;
            } else {
                blockindex = currentPwdBlockindex();
                start = 0;
            }

            StringBuilder part = new StringBuilder();
            for (int i = start; i < pathname.length(); i++) {
                char ch = pathname.charAt(i);
                if (ch == '/') {
                    if (part.isEmpty()) {
                        continue;
                    }
                    int index = findPathBlockindex(blockindex, part.toString());
                    if (index < 1) {
                        if (i == pathname.length() - 1) {
                            break;
                        }
                        return 1;
                    }
                    blockindex = index;
                    part.setLength(0);
                    continue;
                }
                part.append(ch);
                if (part.length() > Types.BLOCK_NAME_MAX_SIZE) {
                    return 2;
                }
            }
            if (part.isEmpty()) {
                return 3;
            }
            String lastname = part.toString();

            byte[] startBlock = new byte[Types.BLOCK_SIZE];
            byte[] block = new byte[Types.BLOCK_SIZE];
            if (!readblock(blockindex, block)) {
                return 1;
            }
            System.arraycopy(block, 0, startBlock, 0, Types.BLOCK_SIZE);
            int startBlockindex = blockindex;

            int stopBlockindex = Util.b4ToU32(block, Types.BLOCK_HEAD + 1 + 14 + 4);
            int offset = Util.b2ToU16(block, Types.BLOCK_HEAD + 1 + 14 + 8);

            boolean done = false;
            int index = startBlockindex;
            while (true) {
                int k = Types.BLOCK_HEAD;
                for (int i = 0; i < Types.BLOCK_ITEM_MAX_COUNT; i++) {
                    byte state = block[k];
                    k++;
                    String entryName = Util.cstrFromFixed(block, k, Types.BLOCK_NAME_MAX_SIZE);
                    k += Types.BLOCK_NAME_MAX_SIZE;
                    if (!lastname.equals(entryName)) {
                        k += 10;
                        if (index == stopBlockindex && k + 1 >= offset) {
                            done = true;
                            break;
                        }
                        continue;
                    }
                    return (state & 0x01) == 0 ? 3 : 4;
                }
                if (done) {
                    break;
                }
                index = Util.b4ToU32(block, 4);
                if (index == 0 || !readblock(index, block)) {
                    return 1;
                }
            }

            return doMkdir(lastname, startBlockindex, startBlock, index, block, stopBlockindex, offset);
        } catch (IOException e) {
            throw new FileFsException("mkdir failed: " + pathname, e);
        }
    }

    private int doMkdir(String lastname, int startBlockindex, byte[] startBlock, int curBlockindex, byte[] curBlock,
                        int stopBlockindex, int offset) throws IOException {
        boolean auto = tmp.state == Types.TXN_NONE;
        if (auto && !tmpStart(Types.TXN_AUTO)) {
            return 1;
        }

        byte[] newBlock = new byte[Types.BLOCK_SIZE];
        byte[] block2 = new byte[Types.BLOCK_SIZE];

        if (offset < Types.BLOCK_SIZE) {
            int newBlockindex = genblockindex();
            if (newBlockindex == 0) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }

            int k = Types.BLOCK_HEAD;
            newBlock[k] = 0;
            k++;
            Util.copyNameInto(newBlock, k, ".");
            k += Types.BLOCK_NAME_MAX_SIZE;
            Util.u32ToB4(newBlockindex, newBlock, k);
            k += 4;
            Util.u32ToB4(newBlockindex, newBlock, k);
            k += 4;
            Util.u16ToB2(Types.BLOCK_HEAD + 2 * Types.ENTRY_SIZE, newBlock, k);
            k += 2;

            newBlock[k] = 0;
            k++;
            Util.copyNameInto(newBlock, k, "..");
            k += Types.BLOCK_NAME_MAX_SIZE;
            Util.u32ToB4(startBlockindex, newBlock, k);

            if (!writeblock(newBlockindex, newBlock)) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }

            k = offset;
            curBlock[k] = 0;
            k++;
            Util.copyNameInto(curBlock, k, lastname);
            k += Types.BLOCK_NAME_MAX_SIZE;
            Util.u32ToB4(newBlockindex, curBlock, k);
            k += 4;
            k += 4;
            k += 2;
            int newOffset = k;

            if (curBlockindex == startBlockindex) {
                Util.u16ToB2(newOffset, curBlock, Types.BLOCK_OFFSET);
                if (!writeblock(curBlockindex, curBlock)) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
            } else {
                if (!writeblock(curBlockindex, curBlock)) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
                Util.u16ToB2(newOffset, startBlock, Types.BLOCK_OFFSET);
                if (!writeblock(startBlockindex, startBlock)) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
            }

            if (auto && !commit()) {
                return 1;
            }
            return 0;
        }

        int newBlockindex = genblockindex();
        int blockindex2 = genblockindex();
        if (newBlockindex == 0 || blockindex2 == 0) {
            if (auto) {
                tmpStop();
            }
            return 1;
        }

        int k = 8;
        Util.u32ToB4(curBlockindex, block2, k);
        k += 4;
        block2[k] = 0;
        k++;
        Util.copyNameInto(block2, k, lastname);
        k += Types.BLOCK_NAME_MAX_SIZE;
        Util.u32ToB4(newBlockindex, block2, k);
        k += 4;
        k += 4;
        k += 2;
        int newOffset = k;

        if (!writeblock(blockindex2, block2)) {
            if (auto) {
                tmpStop();
            }
            return 1;
        }

        Arrays.fill(newBlock, (byte) 0);
        k = Types.BLOCK_HEAD;
        newBlock[k] = 0;
        k++;
        Util.copyNameInto(newBlock, k, ".");
        k += Types.BLOCK_NAME_MAX_SIZE;
        Util.u32ToB4(newBlockindex, newBlock, k);
        k += 4;
        Util.u32ToB4(newBlockindex, newBlock, k);
        k += 4;
        Util.u16ToB2(Types.BLOCK_HEAD + 2 * Types.ENTRY_SIZE, newBlock, k);
        k += 2;
        newBlock[k] = 0;
        k++;
        Util.copyNameInto(newBlock, k, "..");
        k += Types.BLOCK_NAME_MAX_SIZE;
        Util.u32ToB4(startBlockindex, newBlock, k);

        if (!writeblock(newBlockindex, newBlock)) {
            if (auto) {
                tmpStop();
            }
            return 1;
        }

        Util.u16ToB2(newOffset, startBlock, Types.BLOCK_OFFSET);
        Util.u32ToB4(blockindex2, curBlock, 4);
        if (curBlockindex == startBlockindex) {
            Util.u32ToB4(blockindex2, curBlock, Types.BLOCK_STOP_BLOCKINDEX);
            Util.u16ToB2(newOffset, curBlock, Types.BLOCK_OFFSET);
            if (!writeblock(curBlockindex, curBlock)) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }
        } else {
            if (!writeblock(curBlockindex, curBlock)) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }
            Util.u32ToB4(blockindex2, startBlock, Types.BLOCK_STOP_BLOCKINDEX);
            if (!writeblock(startBlockindex, startBlock)) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }
        }

        if (auto && !commit()) {
            return 1;
        }
        return 0;
    }

    private int removeCode(String filename) {
        if (filename == null || filename.isEmpty() || !isMounted()) {
            return 1;
        }
        if (filename.charAt(filename.length() - 1) == '/') {
            return 5;
        }

        try {
            int blockindex;
            int start;
            if (filename.charAt(0) == '/') {
                blockindex = Types.ROOT_BLOCKINDEX;
                start = 1;
            } else {
                blockindex = currentPwdBlockindex();
                start = 0;
            }

            StringBuilder part = new StringBuilder();
            for (int i = start; i < filename.length(); i++) {
                char ch = filename.charAt(i);
                if (ch == '/') {
                    if (part.isEmpty()) {
                        continue;
                    }
                    int index = findPathBlockindex(blockindex, part.toString());
                    if (index < 1) {
                        return 3;
                    }
                    blockindex = index;
                    part.setLength(0);
                    continue;
                }
                part.append(ch);
                if (part.length() > Types.BLOCK_NAME_MAX_SIZE) {
                    return 4;
                }
            }
            if (part.isEmpty()) {
                return 2;
            }
            String lastname = part.toString();
            if (".".equals(lastname) || "..".equals(lastname)) {
                return 5;
            }

            Types.BlockArray[] ba = {new Types.BlockArray(), new Types.BlockArray(), new Types.BlockArray(), new Types.BlockArray()};
            int baUsed = 0;

            byte[] block = new byte[Types.BLOCK_SIZE];
            if (!readblock(blockindex, block)) {
                return 1;
            }
            System.arraycopy(block, 0, ba[0].block, 0, Types.BLOCK_SIZE);
            ba[0].blockindex = blockindex;
            ba[0].active = true;
            byte[] blockHead = ba[0].block;
            int blockHeadIndex = blockindex;
            baUsed = 1;

            int stopBlockindex = Util.b4ToU32(blockHead, Types.BLOCK_HEAD + 1 + 14 + 4);
            int offset = Util.b2ToU16(blockHead, Types.BLOCK_HEAD + 1 + 14 + 8);

            byte[] blockLast;
            int blockLastIndex;
            if (stopBlockindex == blockHeadIndex) {
                blockLast = blockHead;
                blockLastIndex = blockHeadIndex;
            } else {
                if (!readblock(stopBlockindex, ba[1].block)) {
                    return 1;
                }
                ba[1].blockindex = stopBlockindex;
                ba[1].active = true;
                blockLast = ba[1].block;
                blockLastIndex = stopBlockindex;
                baUsed++;
            }

            int fileStart = 0;
            int fileStop = 0;
            int itemOffset = 0;
            byte[] blockItem = null;
            int blockItemIndex = 0;
            boolean flag = false;
            int index = blockHeadIndex;
            while (true) {
                int k = Types.BLOCK_HEAD;
                for (int i = 0; i < Types.BLOCK_ITEM_MAX_COUNT; i++) {
                    byte state = block[k];
                    k++;
                    String entryName = Util.cstrFromFixed(block, k, Types.BLOCK_NAME_MAX_SIZE);
                    k += Types.BLOCK_NAME_MAX_SIZE;
                    if (!lastname.equals(entryName)) {
                        k += 10;
                        if (index == stopBlockindex && k + 1 >= offset) {
                            return 2;
                        }
                        continue;
                    }
                    if ((state & 0x01) == 0) {
                        return 2;
                    }
                    fileStart = Util.b4ToU32(block, k);
                    fileStop = Util.b4ToU32(block, k + 4);
                    itemOffset = k + 10;
                    blockItemIndex = index;

                    boolean reused = false;
                    for (int j = 0; j < baUsed; j++) {
                        if (ba[j].blockindex == index) {
                            blockItem = ba[j].block;
                            reused = true;
                            break;
                        }
                    }
                    if (!reused) {
                        System.arraycopy(block, 0, ba[baUsed].block, 0, Types.BLOCK_SIZE);
                        ba[baUsed].blockindex = index;
                        ba[baUsed].active = true;
                        blockItem = ba[baUsed].block;
                        baUsed++;
                    }
                    flag = true;
                    break;
                }
                if (flag) {
                    break;
                }
                index = Util.b4ToU32(block, 4);
                if (index == 0 || !readblock(index, block)) {
                    return 1;
                }
            }

            boolean auto = tmp.state == Types.TXN_NONE;
            if (auto && !tmpStart(Types.TXN_AUTO)) {
                return 1;
            }

            if (fileStart > 0) {
                byte[] fileBlockStop = new byte[Types.BLOCK_SIZE];
                if (!readblock(fileStop, fileBlockStop)) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
                Util.u32ToB4(tmp.newUnusedBlockhead, fileBlockStop, 4);
                tmp.newUnusedBlockhead = fileStart;
                if (!writeblock(fileStop, fileBlockStop)) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
            }

            if (blockItemIndex != stopBlockindex || itemOffset != offset) {
                System.arraycopy(blockLast, offset - Types.ENTRY_SIZE, blockItem, itemOffset - Types.ENTRY_SIZE, Types.ENTRY_SIZE);
            }
            offset -= Types.ENTRY_SIZE;
            Util.u16ToB2(offset, blockHead, Types.BLOCK_OFFSET);

            if (offset < Types.ENTRY_SIZE) {
                int blockPrevIndex = Util.b4ToU32(blockLast, 8);
                if (!removeblock(blockLastIndex)) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
                int slot = -1;
                for (int i = 0; i < baUsed; i++) {
                    if (ba[i].blockindex == blockLastIndex) {
                        ba[i].active = false;
                        slot = i;
                        break;
                    }
                }
                if (slot < 0) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
                byte[] blockPrev = null;
                for (int i = 0; i < baUsed; i++) {
                    if (ba[i].blockindex == blockPrevIndex) {
                        blockPrev = ba[i].block;
                        break;
                    }
                }
                if (blockPrev == null) {
                    if (!readblock(blockPrevIndex, block)) {
                        if (auto) {
                            tmpStop();
                        }
                        return 1;
                    }
                    System.arraycopy(block, 0, ba[slot].block, 0, Types.BLOCK_SIZE);
                    ba[slot].blockindex = blockPrevIndex;
                    ba[slot].active = true;
                    blockPrev = ba[slot].block;
                }
                Util.u32ToB4(0, blockPrev, 4);
                Util.u32ToB4(blockPrevIndex, blockHead, Types.BLOCK_STOP_BLOCKINDEX);
                offset = Types.BLOCK_SIZE;
                Util.u16ToB2(offset, blockHead, Types.BLOCK_OFFSET);
            }

            for (int i = 0; i < baUsed; i++) {
                if (ba[i].active && !writeblock(ba[i].blockindex, ba[i].block)) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
            }
            if (auto && !commit()) {
                return 1;
            }
            return 0;
        } catch (IOException e) {
            throw new FileFsException("remove failed: " + filename, e);
        }
    }

    private int renameCode(String oldName, String newName) {
        if (oldName == null || oldName.isEmpty() || newName == null || newName.isEmpty() || !isMounted()) {
            return 1;
        }
        try {
            ParsedLeaf oldLeaf = parseLeaf(oldName, 2);
            ParsedLeaf newLeaf = parseLeaf(newName, 3);
            return doRename(oldLeaf.name, oldLeaf.parentBlockindex, oldLeaf.trailingSlash ? 1 : 0,
                newLeaf.name, newLeaf.parentBlockindex, newLeaf.trailingSlash ? 1 : 0);
        } catch (LeafCodeException e) {
            return e.code;
        } catch (IOException e) {
            throw new FileFsException("rename failed", e);
        }
    }

    private int moveCode(String fromName, String toPath) {
        if (fromName == null || fromName.isEmpty() || toPath == null || toPath.isEmpty() || !isMounted()) {
            return 1;
        }
        try {
            ParsedLeaf fromLeaf = parseLeaf(fromName, 2);
            int blockindex;
            int start;
            if (toPath.charAt(0) == '/') {
                blockindex = Types.ROOT_BLOCKINDEX;
                start = 1;
            } else {
                blockindex = currentPwdBlockindex();
                start = 0;
            }
            StringBuilder part = new StringBuilder();
            for (int i = start; i < toPath.length(); i++) {
                char ch = toPath.charAt(i);
                if (ch == '/') {
                    if (part.isEmpty()) {
                        continue;
                    }
                    int index = findPathBlockindex(blockindex, part.toString());
                    if (index < 1) {
                        return 3;
                    }
                    blockindex = index;
                    part.setLength(0);
                    continue;
                }
                part.append(ch);
                if (part.length() > Types.BLOCK_NAME_MAX_SIZE) {
                    return 3;
                }
            }
            if (!part.isEmpty()) {
                int index = findPathBlockindex(blockindex, part.toString());
                if (index < 1) {
                    return 3;
                }
                blockindex = index;
            }
            return doRename(fromLeaf.name, fromLeaf.parentBlockindex, fromLeaf.trailingSlash ? 1 : 0,
                fromLeaf.name, blockindex, fromLeaf.trailingSlash ? 1 : 0);
        } catch (LeafCodeException e) {
            return e.code;
        } catch (IOException e) {
            throw new FileFsException("move failed", e);
        }
    }

    private int copyCode(String fromFilename, String toFilename) {
        if (fromFilename == null || fromFilename.isEmpty() || toFilename == null || toFilename.isEmpty() || !isMounted()) {
            return 1;
        }
        if (fromFilename.charAt(fromFilename.length() - 1) == '/') {
            return 2;
        }
        if (toFilename.charAt(toFilename.length() - 1) == '/') {
            return 3;
        }

        try {
            ParsedLeaf fromLeaf = parseLeaf(fromFilename, 2);
            ParsedLeaf toLeaf = parseLeaf(toFilename, 3);

            byte[] b4buf = new byte[4];
            byte[] fromBlock = new byte[Types.BLOCK_SIZE];
            if (!readblock(fromLeaf.parentBlockindex, fromBlock)) {
                return 1;
            }
            int fromStopBlockindex = Util.b4ToU32(fromBlock, Types.BLOCK_HEAD + 1 + 14 + 4);
            int fromOffset = Util.b2ToU16(fromBlock, Types.BLOCK_HEAD + 1 + 14 + 8);

            int fromFileStart = 0;
            int fromFileStop = 0;
            int fromFileOffset = 0;
            boolean found = false;
            int index = fromLeaf.parentBlockindex;
            while (true) {
                int k = Types.BLOCK_HEAD;
                for (int i = 0; i < Types.BLOCK_ITEM_MAX_COUNT; i++) {
                    byte state = fromBlock[k];
                    k++;
                    String entryName = Util.cstrFromFixed(fromBlock, k, Types.BLOCK_NAME_MAX_SIZE);
                    k += Types.BLOCK_NAME_MAX_SIZE;
                    if (!fromLeaf.name.equals(entryName)) {
                        k += 10;
                        if (index == fromStopBlockindex && k + 1 >= fromOffset) {
                            return 4;
                        }
                        continue;
                    }
                    if ((state & 0x01) != 1) {
                        return 2;
                    }
                    fromFileStart = Util.b4ToU32(fromBlock, k);
                    fromFileStop = Util.b4ToU32(fromBlock, k + 4);
                    fromFileOffset = Util.b2ToU16(fromBlock, k + 8);
                    found = true;
                    break;
                }
                if (found) {
                    break;
                }
                index = Util.b4ToU32(fromBlock, 4);
                if (index == 0 || !readblock(index, fromBlock)) {
                    return 1;
                }
            }

            Types.BlockArray[] toBa = {new Types.BlockArray(), new Types.BlockArray()};
            int toBaUsed = 0;
            byte[] toBlock = new byte[Types.BLOCK_SIZE];
            if (!readblock(toLeaf.parentBlockindex, toBlock)) {
                return 1;
            }
            System.arraycopy(toBlock, 0, toBa[0].block, 0, Types.BLOCK_SIZE);
            toBa[0].blockindex = toLeaf.parentBlockindex;
            toBa[0].active = true;
            byte[] toBlockHead = toBa[0].block;
            int toBlockHeadIndex = toLeaf.parentBlockindex;
            toBaUsed = 1;

            int toStopBlockindex = Util.b4ToU32(toBlockHead, Types.BLOCK_HEAD + 1 + 14 + 4);
            int toOffset = Util.b2ToU16(toBlockHead, Types.BLOCK_HEAD + 1 + 14 + 8);

            byte[] toBlockLast;
            int toBlockLastIndex;
            if (toStopBlockindex == toBlockHeadIndex) {
                toBlockLast = toBlockHead;
                toBlockLastIndex = toBlockHeadIndex;
            } else {
                if (!readblock(toStopBlockindex, toBa[1].block)) {
                    return 1;
                }
                toBa[1].blockindex = toStopBlockindex;
                toBa[1].active = true;
                toBlockLast = toBa[1].block;
                toBlockLastIndex = toStopBlockindex;
                toBaUsed++;
            }

            found = false;
            index = toBlockHeadIndex;
            while (true) {
                int k = Types.BLOCK_HEAD;
                for (int i = 0; i < Types.BLOCK_ITEM_MAX_COUNT; i++) {
                    k++;
                    String entryName = Util.cstrFromFixed(toBlock, k, Types.BLOCK_NAME_MAX_SIZE);
                    k += Types.BLOCK_NAME_MAX_SIZE;
                    if (!toLeaf.name.equals(entryName)) {
                        k += 10;
                        if (index == toStopBlockindex && k + 1 >= toOffset) {
                            found = true;
                            break;
                        }
                        continue;
                    }
                    return 5;
                }
                if (found) {
                    break;
                }
                index = Util.b4ToU32(toBlock, 4);
                if (index == 0 || !readblock(index, toBlock)) {
                    return 1;
                }
            }

            boolean auto = tmp.state == Types.TXN_NONE;
            if (auto && !tmpStart(Types.TXN_AUTO)) {
                return 1;
            }

            byte[] block2 = new byte[Types.BLOCK_SIZE];
            int blockindex2 = 0;
            int newToOffset;

            if (toOffset < Types.BLOCK_SIZE) {
                Arrays.fill(toBlockLast, toOffset, toOffset + Types.ENTRY_SIZE, (byte) 0);
                toBlockLast[toOffset] = 1;
                Util.copyNameInto(toBlockLast, toOffset + 1, toLeaf.name);
                newToOffset = toOffset + Types.ENTRY_SIZE;
                Util.u16ToB2(newToOffset, toBlockHead, Types.BLOCK_OFFSET);
            } else {
                blockindex2 = genblockindex();
                if (blockindex2 == 0) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
                Util.u32ToB4(toBlockLastIndex, block2, 8);
                block2[Types.BLOCK_HEAD] = 1;
                Util.copyNameInto(block2, Types.BLOCK_HEAD + 1, toLeaf.name);
                Util.u32ToB4(blockindex2, toBlockLast, 4);
                newToOffset = Types.BLOCK_HEAD + Types.ENTRY_SIZE;
                Util.u16ToB2(newToOffset, toBlockHead, Types.BLOCK_OFFSET);
                Util.u32ToB4(blockindex2, toBlockHead, Types.BLOCK_STOP_BLOCKINDEX);
            }

            int toFileStart = 0;
            int toFileStop = 0;
            int toFileOffset = 0;

            if (fromFileStart > 0) {
                toFileOffset = fromFileOffset;
                int fromIndex = fromFileStart;
                if (!readblock(fromIndex, fromBlock)) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
                int fromNextIndex = Util.b4ToU32(fromBlock, 4);

                int newBlockindex = genblockindex();
                if (newBlockindex == 0) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
                toFileStart = newBlockindex;
                toFileStop = newBlockindex;

                int prevIndex = 0;
                byte[] newBlock = new byte[Types.BLOCK_SIZE];
                while (true) {
                    System.arraycopy(fromBlock, 0, newBlock, 0, Types.BLOCK_SIZE);
                    Util.u32ToB4(prevIndex, newBlock, 8);

                    if (fromIndex == fromFileStop) {
                        toFileStop = newBlockindex;
                        if (!writeblock(newBlockindex, newBlock)) {
                            if (auto) {
                                tmpStop();
                            }
                            return 1;
                        }
                        break;
                    }

                    prevIndex = newBlockindex;
                    newBlockindex = genblockindex();
                    Util.u32ToB4(newBlockindex, newBlock, 4);
                    if (!writeblock(prevIndex, newBlock)) {
                        if (auto) {
                            tmpStop();
                        }
                        return 1;
                    }

                    fromIndex = fromNextIndex;
                    if (!readblock(fromIndex, fromBlock)) {
                        if (auto) {
                            tmpStop();
                        }
                        return 1;
                    }
                    fromNextIndex = Util.b4ToU32(fromBlock, 4);
                }
            }

            if (toOffset < Types.BLOCK_SIZE) {
                Util.u32ToB4(toFileStart, toBlockLast, toOffset + Types.ENTRY_SIZE - 10);
                Util.u32ToB4(toFileStop, toBlockLast, toOffset + Types.ENTRY_SIZE - 6);
                Util.u16ToB2(toFileOffset, toBlockLast, toOffset + Types.ENTRY_SIZE - 2);
            } else {
                Util.u32ToB4(toFileStart, block2, Types.BLOCK_HEAD + Types.ENTRY_SIZE - 10);
                Util.u32ToB4(toFileStop, block2, Types.BLOCK_HEAD + Types.ENTRY_SIZE - 6);
                Util.u16ToB2(toFileOffset, block2, Types.BLOCK_HEAD + Types.ENTRY_SIZE - 2);
                if (!writeblock(blockindex2, block2)) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
            }

            for (int i = 0; i < toBaUsed; i++) {
                if (toBa[i].active && !writeblock(toBa[i].blockindex, toBa[i].block)) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
            }
            if (auto && !commit()) {
                return 1;
            }
            return 0;
        } catch (LeafCodeException e) {
            return e.code;
        } catch (IOException e) {
            throw new FileFsException("copy failed", e);
        }
    }

    private int rmdirCode(String pathname) {
        if (pathname == null || pathname.isEmpty() || !isMounted()) {
            return 1;
        }
        try {
            ParsedLeaf leaf = parseLeaf(pathname, 4);
            if (".".equals(leaf.name) || "..".equals(leaf.name)) {
                return 1;
            }

            Types.BlockArray[] ba = {new Types.BlockArray(), new Types.BlockArray(), new Types.BlockArray(), new Types.BlockArray()};
            int baUsed = 0;
            byte[] block = new byte[Types.BLOCK_SIZE];
            if (!readblock(leaf.parentBlockindex, block)) {
                return 1;
            }
            System.arraycopy(block, 0, ba[0].block, 0, Types.BLOCK_SIZE);
            ba[0].blockindex = leaf.parentBlockindex;
            ba[0].active = true;
            byte[] blockHead = ba[0].block;
            int blockHeadIndex = leaf.parentBlockindex;
            baUsed = 1;

            int stopBlockindex = Util.b4ToU32(blockHead, Types.BLOCK_HEAD + 1 + 14 + 4);
            int offset = Util.b2ToU16(blockHead, Types.BLOCK_HEAD + 1 + 14 + 8);

            byte[] blockLast;
            int blockLastIndex;
            if (stopBlockindex == blockHeadIndex) {
                blockLast = blockHead;
                blockLastIndex = blockHeadIndex;
            } else {
                if (!readblock(stopBlockindex, ba[1].block)) {
                    return 1;
                }
                ba[1].blockindex = stopBlockindex;
                ba[1].active = true;
                blockLast = ba[1].block;
                blockLastIndex = stopBlockindex;
                baUsed++;
            }

            int subdirblockindex = 0;
            byte[] subdirblock = new byte[Types.BLOCK_SIZE];
            int itemOffset = 0;
            byte[] blockItem = null;
            int blockItemIndex = 0;
            boolean flag = false;
            int index = blockHeadIndex;
            while (true) {
                int k = Types.BLOCK_HEAD;
                for (int i = 0; i < Types.BLOCK_ITEM_MAX_COUNT; i++) {
                    byte state = block[k];
                    k++;
                    String entryName = Util.cstrFromFixed(block, k, Types.BLOCK_NAME_MAX_SIZE);
                    k += Types.BLOCK_NAME_MAX_SIZE;
                    if (!leaf.name.equals(entryName)) {
                        k += 10;
                        if (index == stopBlockindex && k + 1 >= offset) {
                            return 3;
                        }
                        continue;
                    }
                    if ((state & 0x01) == 1) {
                        return 3;
                    }
                    subdirblockindex = Util.b4ToU32(block, k);
                    if (!readblock(subdirblockindex, subdirblock)) {
                        return 1;
                    }
                    int subdirStart = Util.b4ToU32(subdirblock, Types.BLOCK_START_BLOCKINDEX);
                    int subdirStop = Util.b4ToU32(subdirblock, Types.BLOCK_STOP_BLOCKINDEX);
                    int subdirOffset = Util.b2ToU16(subdirblock, Types.BLOCK_OFFSET);
                    if (subdirStop != subdirStart || subdirOffset > 62) {
                        return 2;
                    }
                    itemOffset = k + 10;
                    blockItemIndex = index;
                    boolean reused = false;
                    for (int j = 0; j < baUsed; j++) {
                        if (ba[j].blockindex == index) {
                            blockItem = ba[j].block;
                            reused = true;
                            break;
                        }
                    }
                    if (!reused) {
                        System.arraycopy(block, 0, ba[baUsed].block, 0, Types.BLOCK_SIZE);
                        ba[baUsed].blockindex = index;
                        ba[baUsed].active = true;
                        blockItem = ba[baUsed].block;
                        baUsed++;
                    }
                    flag = true;
                    break;
                }
                if (flag) {
                    break;
                }
                index = Util.b4ToU32(block, 4);
                if (index == 0 || !readblock(index, block)) {
                    return 1;
                }
            }

            boolean auto = tmp.state == Types.TXN_NONE;
            if (auto && !tmpStart(Types.TXN_AUTO)) {
                return 1;
            }
            if (!removeblock(subdirblockindex)) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }

            if (blockItemIndex != stopBlockindex || itemOffset != offset) {
                System.arraycopy(blockLast, offset - Types.ENTRY_SIZE, blockItem, itemOffset - Types.ENTRY_SIZE, Types.ENTRY_SIZE);
            }
            offset -= Types.ENTRY_SIZE;
            Util.u16ToB2(offset, blockHead, Types.BLOCK_OFFSET);

            if (offset < Types.ENTRY_SIZE) {
                int blockPrevIndex = Util.b4ToU32(blockLast, 8);
                if (!removeblock(blockLastIndex)) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
                int slot = -1;
                for (int i = 0; i < baUsed; i++) {
                    if (ba[i].blockindex == blockLastIndex) {
                        ba[i].active = false;
                        slot = i;
                        break;
                    }
                }
                if (slot < 0) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
                byte[] blockPrev = null;
                for (int i = 0; i < baUsed; i++) {
                    if (ba[i].blockindex == blockPrevIndex) {
                        blockPrev = ba[i].block;
                        break;
                    }
                }
                if (blockPrev == null) {
                    if (!readblock(blockPrevIndex, block)) {
                        if (auto) {
                            tmpStop();
                        }
                        return 1;
                    }
                    System.arraycopy(block, 0, ba[slot].block, 0, Types.BLOCK_SIZE);
                    ba[slot].blockindex = blockPrevIndex;
                    ba[slot].active = true;
                    blockPrev = ba[slot].block;
                }
                Util.u32ToB4(0, blockPrev, 4);
                Util.u32ToB4(blockPrevIndex, blockHead, Types.BLOCK_STOP_BLOCKINDEX);
                offset = Types.BLOCK_SIZE;
                Util.u16ToB2(offset, blockHead, Types.BLOCK_OFFSET);
            }

            for (int i = 0; i < baUsed; i++) {
                if (ba[i].active && !writeblock(ba[i].blockindex, ba[i].block)) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
            }
            if (auto && !commit()) {
                return 1;
            }
            return 0;
        } catch (LeafCodeException e) {
            return e.code;
        } catch (IOException e) {
            throw new FileFsException("rmdir failed", e);
        }
    }

    private int doRename(String oldLastname, int oldBlockindex, int oldTypeDir,
                         String newLastname, int newBlockindex, int newTypeDir) throws IOException {
        Types.BlockArray[] oldBa = {new Types.BlockArray(), new Types.BlockArray(), new Types.BlockArray(), new Types.BlockArray()};
        int oldBaUsed = 0;
        byte[] oldBlock = new byte[Types.BLOCK_SIZE];
        if (!readblock(oldBlockindex, oldBlock)) {
            return 1;
        }
        System.arraycopy(oldBlock, 0, oldBa[0].block, 0, Types.BLOCK_SIZE);
        oldBa[0].blockindex = oldBlockindex;
        oldBa[0].active = true;
        byte[] oldBlockHead = oldBa[0].block;
        int oldBlockHeadIndex = oldBlockindex;
        oldBaUsed = 1;

        int oldStopBlockindex = Util.b4ToU32(oldBlockHead, Types.BLOCK_HEAD + 1 + 14 + 4);
        int oldOffset = Util.b2ToU16(oldBlockHead, Types.BLOCK_HEAD + 1 + 14 + 8);

        byte[] oldBlockLast;
        int oldBlockLastIndex;
        if (oldStopBlockindex == oldBlockHeadIndex) {
            oldBlockLast = oldBlockHead;
            oldBlockLastIndex = oldBlockHeadIndex;
        } else {
            if (!readblock(oldStopBlockindex, oldBa[1].block)) {
                return 1;
            }
            oldBa[1].blockindex = oldStopBlockindex;
            oldBa[1].active = true;
            oldBlockLast = oldBa[1].block;
            oldBlockLastIndex = oldStopBlockindex;
            oldBaUsed++;
        }

        int oldItemOffset = 0;
        int oldDirFile = 0;
        byte[] oldBlockItem = null;
        int oldBlockItemIndex = 0;
        boolean flag = false;
        int index = oldBlockHeadIndex;
        while (true) {
            int k = Types.BLOCK_HEAD;
            for (int i = 0; i < Types.BLOCK_ITEM_MAX_COUNT; i++) {
                byte state = oldBlock[k];
                k++;
                String entryName = Util.cstrFromFixed(oldBlock, k, Types.BLOCK_NAME_MAX_SIZE);
                k += Types.BLOCK_NAME_MAX_SIZE;
                if (!oldLastname.equals(entryName)) {
                    k += 10;
                    if (index == oldStopBlockindex && k + 1 >= oldOffset) {
                        return 4;
                    }
                    continue;
                }
                oldDirFile = state & 0x01;
                if (oldTypeDir == 1 && oldDirFile == 1) {
                    return 2;
                }
                if (newTypeDir == 1 && oldDirFile == 1) {
                    return 6;
                }
                oldItemOffset = k + 10;
                oldBlockItemIndex = index;
                boolean reused = false;
                for (int j = 0; j < oldBaUsed; j++) {
                    if (oldBa[j].blockindex == index) {
                        oldBlockItem = oldBa[j].block;
                        reused = true;
                        break;
                    }
                }
                if (!reused) {
                    System.arraycopy(oldBlock, 0, oldBa[oldBaUsed].block, 0, Types.BLOCK_SIZE);
                    oldBa[oldBaUsed].blockindex = index;
                    oldBa[oldBaUsed].active = true;
                    oldBlockItem = oldBa[oldBaUsed].block;
                    oldBaUsed++;
                }
                flag = true;
                break;
            }
            if (flag) {
                break;
            }
            index = Util.b4ToU32(oldBlock, 4);
            if (index == 0 || !readblock(index, oldBlock)) {
                return 1;
            }
        }

        Types.BlockArray[] newBa = {new Types.BlockArray(), new Types.BlockArray()};
        int newBaUsed = 0;
        byte[] newBlock = new byte[Types.BLOCK_SIZE];
        if (!readblock(newBlockindex, newBlock)) {
            return 1;
        }
        System.arraycopy(newBlock, 0, newBa[0].block, 0, Types.BLOCK_SIZE);
        newBa[0].blockindex = newBlockindex;
        newBa[0].active = true;
        byte[] newBlockHead = newBa[0].block;
        int newBlockHeadIndex = newBlockindex;
        newBaUsed = 1;

        int newStopBlockindex = Util.b4ToU32(newBlockHead, Types.BLOCK_HEAD + 1 + 14 + 4);
        int newOffset = Util.b2ToU16(newBlockHead, Types.BLOCK_HEAD + 1 + 14 + 8);

        byte[] newBlockLast;
        int newBlockLastIndex;
        if (newStopBlockindex == newBlockHeadIndex) {
            newBlockLast = newBlockHead;
            newBlockLastIndex = newBlockHeadIndex;
        } else {
            if (!readblock(newStopBlockindex, newBa[1].block)) {
                return 1;
            }
            newBa[1].blockindex = newStopBlockindex;
            newBa[1].active = true;
            newBlockLast = newBa[1].block;
            newBlockLastIndex = newStopBlockindex;
            newBaUsed++;
        }

        flag = false;
        index = newBlockHeadIndex;
        while (true) {
            int k = Types.BLOCK_HEAD;
            for (int i = 0; i < Types.BLOCK_ITEM_MAX_COUNT; i++) {
                k++;
                String entryName = Util.cstrFromFixed(newBlock, k, Types.BLOCK_NAME_MAX_SIZE);
                k += Types.BLOCK_NAME_MAX_SIZE;
                if (!newLastname.equals(entryName)) {
                    k += 10;
                    if (index == newStopBlockindex && k + 1 >= newOffset) {
                        flag = true;
                        break;
                    }
                    continue;
                }
                return 5;
            }
            if (flag) {
                break;
            }
            index = Util.b4ToU32(newBlock, 4);
            if (index == 0 || !readblock(index, newBlock)) {
                return 1;
            }
        }

        boolean auto = tmp.state == Types.TXN_NONE;
        if (oldBlockHeadIndex == newBlockHeadIndex) {
            Util.copyNameInto(oldBlockItem, oldItemOffset - 24, newLastname);
            if (auto && !tmpStart(Types.TXN_AUTO)) {
                return 1;
            }
            if (!writeblock(oldBlockItemIndex, oldBlockItem)) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }
            if (auto && !commit()) {
                return 1;
            }
            return 0;
        }

        if (auto && !tmpStart(Types.TXN_AUTO)) {
            return 1;
        }

        if (oldDirFile == 0) {
            int pathBlockindex = Util.b4ToU32(oldBlockItem, oldItemOffset - 10);
            byte[] pathBlock = new byte[Types.BLOCK_SIZE];
            if (!readblock(pathBlockindex, pathBlock)) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }
            Util.u32ToB4(newBlockHeadIndex, pathBlock, Types.BLOCK_HEAD + Types.ENTRY_SIZE + 1 + 14);
            if (!writeblock(pathBlockindex, pathBlock)) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }
        }

        byte[] block2 = new byte[Types.BLOCK_SIZE];
        int blockindex2 = 0;
        if (newOffset < Types.BLOCK_SIZE) {
            System.arraycopy(oldBlockItem, oldItemOffset - Types.ENTRY_SIZE, newBlockLast, newOffset, Types.ENTRY_SIZE);
            Util.copyNameInto(newBlockLast, newOffset + 1, newLastname);
            newOffset += Types.ENTRY_SIZE;
            Util.u16ToB2(newOffset, newBlockHead, Types.BLOCK_OFFSET);
        } else {
            blockindex2 = genblockindex();
            if (blockindex2 == 0) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }
            Util.u32ToB4(newBlockLastIndex, block2, 8);
            System.arraycopy(oldBlockItem, oldItemOffset - Types.ENTRY_SIZE, block2, Types.BLOCK_HEAD, Types.ENTRY_SIZE);
            Util.copyNameInto(block2, Types.BLOCK_HEAD + 1, newLastname);
            if (!writeblock(blockindex2, block2)) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }
            Util.u32ToB4(blockindex2, newBlockLast, 4);
            newOffset = Types.BLOCK_HEAD + Types.ENTRY_SIZE;
            Util.u16ToB2(newOffset, newBlockHead, Types.BLOCK_OFFSET);
            Util.u32ToB4(blockindex2, newBlockHead, Types.BLOCK_STOP_BLOCKINDEX);
        }

        for (int i = 0; i < newBaUsed; i++) {
            if (newBa[i].active && !writeblock(newBa[i].blockindex, newBa[i].block)) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }
        }

        if (oldBlockItemIndex != oldStopBlockindex || oldItemOffset != oldOffset) {
            System.arraycopy(oldBlockLast, oldOffset - Types.ENTRY_SIZE, oldBlockItem, oldItemOffset - Types.ENTRY_SIZE, Types.ENTRY_SIZE);
        }
        oldOffset -= Types.ENTRY_SIZE;
        Util.u16ToB2(oldOffset, oldBlockHead, Types.BLOCK_OFFSET);

        if (oldOffset < Types.ENTRY_SIZE) {
            int oldBlockPrevIndex = Util.b4ToU32(oldBlockLast, 8);
            if (!removeblock(oldBlockLastIndex)) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }
            int slot = -1;
            for (int i = 0; i < oldBaUsed; i++) {
                if (oldBa[i].blockindex == oldBlockLastIndex) {
                    oldBa[i].active = false;
                    slot = i;
                    break;
                }
            }
            if (slot < 0) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }
            byte[] oldBlockPrev = null;
            for (int i = 0; i < oldBaUsed; i++) {
                if (oldBa[i].blockindex == oldBlockPrevIndex) {
                    oldBlockPrev = oldBa[i].block;
                    break;
                }
            }
            if (oldBlockPrev == null) {
                if (!readblock(oldBlockPrevIndex, oldBlock)) {
                    if (auto) {
                        tmpStop();
                    }
                    return 1;
                }
                System.arraycopy(oldBlock, 0, oldBa[slot].block, 0, Types.BLOCK_SIZE);
                oldBa[slot].blockindex = oldBlockPrevIndex;
                oldBa[slot].active = true;
                oldBlockPrev = oldBa[slot].block;
            }
            Util.u32ToB4(0, oldBlockPrev, 4);
            Util.u32ToB4(oldBlockPrevIndex, oldBlockHead, Types.BLOCK_STOP_BLOCKINDEX);
            oldOffset = Types.BLOCK_SIZE;
            Util.u16ToB2(oldOffset, oldBlockHead, Types.BLOCK_OFFSET);
        }

        for (int i = 0; i < oldBaUsed; i++) {
            if (oldBa[i].active && !writeblock(oldBa[i].blockindex, oldBa[i].block)) {
                if (auto) {
                    tmpStop();
                }
                return 1;
            }
        }
        if (auto && !commit()) {
            return 1;
        }
        return 0;
    }

    private ParsedLeaf parseLeaf(String path, int code) throws IOException, LeafCodeException {
        int blockindex;
        int start;
        if (path.charAt(0) == '/') {
            blockindex = Types.ROOT_BLOCKINDEX;
            start = 1;
        } else {
            blockindex = currentPwdBlockindex();
            start = 0;
        }

        StringBuilder part = new StringBuilder();
        for (int i = start; i < path.length(); i++) {
            char ch = path.charAt(i);
            if (ch == '/') {
                if (part.isEmpty()) {
                    continue;
                }
                if (i == path.length() - 1) {
                    break;
                }
                int index = findPathBlockindex(blockindex, part.toString());
                if (index < 1) {
                    throw new LeafCodeException(code);
                }
                blockindex = index;
                part.setLength(0);
                continue;
            }
            part.append(ch);
            if (part.length() > Types.BLOCK_NAME_MAX_SIZE) {
                throw new LeafCodeException(code);
            }
        }
        if (part.length() > Types.BLOCK_NAME_MAX_SIZE || part.isEmpty()) {
            throw new LeafCodeException(code == 4 ? 3 : code);
        }
        String name = part.toString();
        if (".".equals(name) || "..".equals(name)) {
            throw new LeafCodeException(code);
        }
        return new ParsedLeaf(blockindex, name, path.charAt(path.length() - 1) == '/');
    }

    private int findPathBlockindex(int blockindex, String pathname) throws IOException {
        byte[] block = new byte[Types.BLOCK_SIZE];
        int index = blockindex;
        if (!readblock(index, block)) {
            return 0;
        }
        int stopBlockindex = Util.b4ToU32(block, 12 + 1 + 14 + 4);
        int offset = Util.b2ToU16(block, 12 + 1 + 14 + 4 + 4);

        while (true) {
            int k = Types.BLOCK_HEAD;
            for (int i = 0; i < Types.BLOCK_ITEM_MAX_COUNT; i++) {
                byte state = block[k];
                k++;
                int dirFile = state & 0x01;
                if (dirFile == 1) {
                    k += 24;
                    if (index == stopBlockindex && k + 1 >= offset) {
                        return 0;
                    }
                    continue;
                }
                String name = Util.cstrFromFixed(block, k, Types.BLOCK_NAME_MAX_SIZE);
                k += Types.BLOCK_NAME_MAX_SIZE;
                if (!pathname.equals(name)) {
                    k += 10;
                    if (index == stopBlockindex && k + 1 >= offset) {
                        return 0;
                    }
                    continue;
                }
                return Util.b4ToU32(block, k);
            }
            index = Util.b4ToU32(block, 4);
            if (index == 0 || !readblock(index, block)) {
                return 0;
            }
        }
    }

    private int genblockindex() throws IOException {
        byte[] block = new byte[Types.BLOCK_SIZE];
        if (tmp.newUnusedBlockhead > 0) {
            int blockindex = tmp.newUnusedBlockhead;
            if (!readblock(blockindex, block)) {
                return 0;
            }
            tmp.newUnusedBlockhead = Util.b4ToU32(block, 4);
            return blockindex;
        }

        int blockindex = tmp.newTotalBlocksize;
        int addindex = blockindex - tmp.totalBlocksize;
        Util.setPos(tmp.fpAdd, (long) addindex * (4L + Types.BLOCK_SIZE));
        byte[] b4 = new byte[4];
        Util.u32ToB4(blockindex, b4, 0);
        tmp.fpAdd.write(b4);
        tmp.fpAdd.write(block);
        tmp.newTotalBlocksize++;
        return blockindex;
    }

    private boolean readblock(int blockindex, byte[] block) throws IOException {
        Util.setPos(fp, (long) blockindex * Types.BLOCK_SIZE);
        byte[] buf = new byte[4];
        if (!tryReadExact(fp, buf, 0, 4)) {
            if (tmp.state == Types.TXN_NONE) {
                return false;
            }
            if (blockindex < tmp.totalBlocksize) {
                return false;
            }
            int addindex = blockindex - tmp.totalBlocksize;
            Util.setPos(tmp.fpAdd, (long) addindex * (Types.BLOCK_SIZE + 4L) + 4L);
            return tryReadExact(tmp.fpAdd, block, 0, Types.BLOCK_SIZE);
        }

        if (tmp.state == Types.TXN_NONE) {
            System.arraycopy(buf, 0, block, 0, 4);
            return tryReadExact(fp, block, 4, Types.BLOCK_SIZE - 4);
        }

        int cpindex = Util.b4ToU32(buf, 0);
        Util.setPos(tmp.fpCp, (long) cpindex * (Types.BLOCK_SIZE + 4L));
        byte[] b4 = new byte[4];
        if (!tryReadExact(tmp.fpCp, b4, 0, 4)) {
            System.arraycopy(buf, 0, block, 0, 4);
            return tryReadExact(fp, block, 4, Types.BLOCK_SIZE - 4);
        }
        int orgindex = Util.b4ToU32(b4, 0);
        if (orgindex != blockindex) {
            System.arraycopy(buf, 0, block, 0, 4);
            return tryReadExact(fp, block, 4, Types.BLOCK_SIZE - 4);
        }
        return tryReadExact(tmp.fpCp, block, 0, Types.BLOCK_SIZE);
    }

    private boolean writeblock(int blockindex, byte[] block) throws IOException {
        if (tmp.state == Types.TXN_NONE) {
            return false;
        }

        Util.setPos(fp, (long) blockindex * Types.BLOCK_SIZE);
        byte[] buf = new byte[4];
        if (!tryReadExact(fp, buf, 0, 4)) {
            if (blockindex < tmp.totalBlocksize) {
                return false;
            }
            int addindex = blockindex - tmp.totalBlocksize;
            Util.setPos(tmp.fpAdd, (long) addindex * (Types.BLOCK_SIZE + 4L) + 4L);
            tmp.fpAdd.write(block);
            return true;
        }

        int cpindex = Util.b4ToU32(buf, 0);
        Util.setPos(tmp.fpCp, (long) cpindex * (Types.BLOCK_SIZE + 4L));
        byte[] b4 = new byte[4];
        if (!tryReadExact(tmp.fpCp, b4, 0, 4) || Util.b4ToU32(b4, 0) != blockindex) {
            cpindex = tmp.cpSize;
            Util.setPos(tmp.fpCp, (long) cpindex * (Types.BLOCK_SIZE + 4L));
            Util.u32ToB4(blockindex, b4, 0);
            tmp.fpCp.write(b4);
            tmp.fpCp.write(block);

            Util.setPos(fp, (long) blockindex * Types.BLOCK_SIZE);
            Util.u32ToB4(cpindex, b4, 0);
            fp.write(b4);
            tmp.cpSize++;
            return true;
        }

        Util.setPos(tmp.fpCp, (long) cpindex * (Types.BLOCK_SIZE + 4L) + 4L);
        tmp.fpCp.write(block);
        return true;
    }

    private boolean removeblock(int blockindex) throws IOException {
        if (tmp.state == Types.TXN_NONE) {
            return false;
        }

        Util.setPos(fp, (long) blockindex * Types.BLOCK_SIZE);
        byte[] buf = new byte[4];
        if (!tryReadExact(fp, buf, 0, 4)) {
            if (blockindex < tmp.totalBlocksize) {
                return false;
            }
            int addindex = blockindex - tmp.totalBlocksize;
            Util.setPos(tmp.fpAdd, (long) addindex * (Types.BLOCK_SIZE + 4L) + 8L);
            byte[] b4 = new byte[4];
            Util.u32ToB4(tmp.newUnusedBlockhead, b4, 0);
            tmp.fpAdd.write(b4);
            tmp.newUnusedBlockhead = blockindex;
            return true;
        }

        int cpindex = Util.b4ToU32(buf, 0);
        Util.setPos(tmp.fpCp, (long) cpindex * (Types.BLOCK_SIZE + 4L));
        byte[] b4 = new byte[4];
        if (!tryReadExact(tmp.fpCp, b4, 0, 4) || Util.b4ToU32(b4, 0) != blockindex) {
            cpindex = tmp.cpSize;
            Util.setPos(tmp.fpCp, (long) cpindex * (Types.BLOCK_SIZE + 4L));
            Util.u32ToB4(blockindex, b4, 0);
            tmp.fpCp.write(b4);
            byte[] freeBlock = new byte[Types.BLOCK_SIZE];
            Util.u32ToB4(tmp.newUnusedBlockhead, freeBlock, 0);
            tmp.fpCp.write(freeBlock);

            Util.setPos(fp, (long) blockindex * Types.BLOCK_SIZE);
            Util.u32ToB4(cpindex, b4, 0);
            fp.write(b4);
            tmp.cpSize++;
            tmp.newUnusedBlockhead = blockindex;
            return true;
        }

        Util.setPos(tmp.fpCp, (long) cpindex * (Types.BLOCK_SIZE + 4L) + 8L);
        Util.u32ToB4(tmp.newUnusedBlockhead, b4, 0);
        tmp.fpCp.write(b4);
        tmp.newUnusedBlockhead = blockindex;
        return true;
    }

    private boolean tmpStart(byte state) throws IOException {
        if (state == 0) {
            return false;
        }
        if (tmp.state != Types.TXN_NONE) {
            tmpStop();
        }

        byte[] block = new byte[12];
        Util.rewind(fp);
        if (!tryReadExact(fp, block, 0, 12)) {
            return false;
        }
        tmp.totalBlocksize = Util.b4ToU32(block, 4);
        tmp.unusedBlockhead = Util.b4ToU32(block, 8);
        tmp.newTotalBlocksize = tmp.totalBlocksize;
        tmp.newUnusedBlockhead = tmp.unusedBlockhead;

        tmp.cpPath = Files.createTempFile("filefs-cp-", "");
        tmp.fpCp = new RandomAccessFile(tmp.cpPath.toFile(), "rw");
        try {
            tmp.addPath = Files.createTempFile("filefs-add-", "");
            tmp.fpAdd = new RandomAccessFile(tmp.addPath.toFile(), "rw");
        } catch (IOException e) {
            tmpStop();
            return false;
        }

        tmp.pwd = pwd;
        tmp.pwdBlockindex = pwdBlockindex;
        tmp.cpSize = 0;
        tmp.state = state;
        return true;
    }

    private void tmpStop() {
        tryClose(tmp.fpCp);
        tryClose(tmp.fpAdd);
        tmp.fpCp = null;
        tmp.fpAdd = null;
        tryDelete(tmp.cpPath);
        tryDelete(tmp.addPath);
        tmp.cpPath = null;
        tmp.addPath = null;
        tmp.cpSize = 0;
        tmp.state = Types.TXN_NONE;
    }

    private void applyJournal() throws IOException {
        if (journalPath == null || !Files.exists(journalPath)) {
            return;
        }

        try (RandomAccessFile journal = new RandomAccessFile(journalPath.toFile(), "r")) {
            int state = journal.read();
            if (state != 0xFF) {
                return;
            }

            byte[] indexBlock = new byte[4 + Types.BLOCK_SIZE];
            while (tryReadExact(journal, indexBlock, 0, indexBlock.length)) {
                int index = Util.b4ToU32(indexBlock, 0);
                Util.setPos(fp, (long) index * Types.BLOCK_SIZE);
                fp.write(indexBlock, 4, Types.BLOCK_SIZE);
            }
            Util.flush(fp);
        } finally {
            Files.deleteIfExists(journalPath);
        }
    }

    private int currentPwdBlockindex() {
        return tmp.state == Types.TXN_NONE ? pwdBlockindex : tmp.pwdBlockindex;
    }

    private String currentPwd() {
        return tmp.state == Types.TXN_NONE ? pwd : tmp.pwd;
    }

    private void requireMounted() {
        if (!isMounted()) {
            throw new FileFsException("filesystem is not mounted");
        }
    }

    private boolean tryReadExact(RandomAccessFile file, byte[] bytes, int off, int len) throws IOException {
        try {
            file.readFully(bytes, off, len);
            return true;
        } catch (EOFException e) {
            return false;
        }
    }

    private void tryClose(RandomAccessFile file) {
        if (file == null) {
            return;
        }
        try {
            file.close();
        } catch (IOException ignored) {
        }
    }

    private void tryDelete(Path path) {
        if (path == null) {
            return;
        }
        try {
            Files.deleteIfExists(path);
        } catch (IOException ignored) {
        }
    }

    private static final class ParsedLeaf {
        final int parentBlockindex;
        final String name;
        final boolean trailingSlash;

        ParsedLeaf(int parentBlockindex, String name, boolean trailingSlash) {
            this.parentBlockindex = parentBlockindex;
            this.name = name;
            this.trailingSlash = trailingSlash;
        }
    }

    private static final class LeafCodeException extends Exception {
        final int code;

        LeafCodeException(int code) {
            this.code = code;
        }
    }

    private static final class IntBox {
        int value;

        IntBox(int value) {
            this.value = value;
        }
    }
}
