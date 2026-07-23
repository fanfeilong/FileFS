package com.filefs;

public final class FileFsException extends RuntimeException {
    public FileFsException(String message) {
        super(message);
    }

    public FileFsException(String message, Throwable cause) {
        super(message, cause);
    }
}
