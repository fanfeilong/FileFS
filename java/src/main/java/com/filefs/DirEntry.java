package com.filefs;

public final class DirEntry {
    private final FileType type;
    private final String name;

    DirEntry(FileType type, String name) {
        this.type = type;
        this.name = name;
    }

    public FileType type() {
        return type;
    }

    public String name() {
        return name;
    }

    public int nameLength() {
        return name.length();
    }
}
