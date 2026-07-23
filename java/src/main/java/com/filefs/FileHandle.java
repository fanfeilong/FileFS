package com.filefs;

public final class FileHandle implements AutoCloseable {
    int mode;

    int dirBlockindex;
    int dirOffset;

    int fileStartBlockindex;
    int fileStopBlockindex;
    int fileOffset;

    int posBlockindex;
    int posOffset;
    long pos;

    boolean open = true;

    FileHandle() {
    }

    public boolean isOpen() {
        return open;
    }

    @Override
    public void close() {
        open = false;
    }
}
