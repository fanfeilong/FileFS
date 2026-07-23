package com.filefs;

import java.io.RandomAccessFile;
import java.nio.file.Path;

final class Types {
    static final int BLOCK_SIZE = 512;
    static final int BLOCK_ITEM_MAX_COUNT = 20;
    static final int BLOCK_HEAD = 12;
    static final int BLOCK_NAME_MAX_SIZE = 14;
    static final int BLOCK_START_BLOCKINDEX = 27;
    static final int BLOCK_STOP_BLOCKINDEX = 31;
    static final int BLOCK_OFFSET = 35;
    static final int ENTRY_SIZE = 25;
    static final int ROOT_BLOCKINDEX = 1;

    static final byte TXN_NONE = 0;
    static final byte TXN_AUTO = 1;
    static final byte TXN_MANUAL = 2;

    static final byte[] MAGIC = new byte[] {(byte) 0x78, 0x11, 0x45, 0x14};

    private Types() {
    }

    static final class TxState {
        byte state;
        String pwd = "";
        int pwdBlockindex;

        RandomAccessFile fpCp;
        RandomAccessFile fpAdd;
        Path cpPath;
        Path addPath;

        int cpSize;

        int totalBlocksize;
        int unusedBlockhead;
        int newTotalBlocksize;
        int newUnusedBlockhead;
    }

    static final class BlockArray {
        boolean active;
        final byte[] block = new byte[BLOCK_SIZE];
        int blockindex;
    }
}
