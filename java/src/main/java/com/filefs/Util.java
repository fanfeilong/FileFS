package com.filefs;

import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;

final class Util {
    private Util() {
    }

    static int b4ToU32(byte[] bytes, int offset) {
        return (bytes[offset] & 0xFF)
            | ((bytes[offset + 1] & 0xFF) << 8)
            | ((bytes[offset + 2] & 0xFF) << 16)
            | ((bytes[offset + 3] & 0xFF) << 24);
    }

    static void u32ToB4(int value, byte[] bytes, int offset) {
        bytes[offset] = (byte) (value & 0xFF);
        bytes[offset + 1] = (byte) ((value >>> 8) & 0xFF);
        bytes[offset + 2] = (byte) ((value >>> 16) & 0xFF);
        bytes[offset + 3] = (byte) ((value >>> 24) & 0xFF);
    }

    static int b2ToU16(byte[] bytes, int offset) {
        return (bytes[offset] & 0xFF) | ((bytes[offset + 1] & 0xFF) << 8);
    }

    static void u16ToB2(int value, byte[] bytes, int offset) {
        bytes[offset] = (byte) (value & 0xFF);
        bytes[offset + 1] = (byte) ((value >>> 8) & 0xFF);
    }

    static void rewind(RandomAccessFile file) throws IOException {
        file.seek(0L);
    }

    static void setPos(RandomAccessFile file, long pos) throws IOException {
        file.seek(pos);
    }

    static void flush(RandomAccessFile file) throws IOException {
        file.getFD().sync();
    }

    static String cstrFromFixed(byte[] bytes, int offset, int len) {
        int end = 0;
        while (end < len && bytes[offset + end] != 0) {
            end++;
        }
        return new String(bytes, offset, end, StandardCharsets.US_ASCII);
    }

    static void clear(byte[] bytes, int offset, int len) {
        for (int i = 0; i < len; i++) {
            bytes[offset + i] = 0;
        }
    }

    static void copyNameInto(byte[] dst, int offset, String name) {
        clear(dst, offset, Types.BLOCK_NAME_MAX_SIZE);
        int n = Math.min(name.length(), Types.BLOCK_NAME_MAX_SIZE);
        for (int i = 0; i < n; i++) {
            dst[offset + i] = (byte) name.charAt(i);
        }
    }

    static Path journalPathFor(Path imagePath) {
        return Path.of(imagePath.toString() + "-j");
    }
}
