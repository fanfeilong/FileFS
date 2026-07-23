package com.filefs;

public enum SeekWhence {
    SET(0),
    CUR(1),
    END(2);

    private final int code;

    SeekWhence(int code) {
        this.code = code;
    }

    int code() {
        return code;
    }
}
