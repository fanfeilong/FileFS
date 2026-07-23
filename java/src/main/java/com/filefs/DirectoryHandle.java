package com.filefs;

public final class DirectoryHandle implements AutoCloseable {
    int blockindex;
    final byte[] block = new byte[Types.BLOCK_SIZE];
    int searchindex;
    int stopBlockindex;
    int offset;
    String absolutePath = "/";
    boolean open = true;

    DirectoryHandle() {
    }

    public boolean isOpen() {
        return open;
    }

    public String absolutePath() {
        return absolutePath;
    }

    @Override
    public void close() {
        open = false;
    }
}
