package com.filefs;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;

class FileSystemTest {
    @Test
    void mkfsMountAndGetcwd() throws IOException {
        try (ImageFixture fixture = new ImageFixture("lifecycle")) {
            assertTrue(fixture.fs.isMounted());
            assertEquals("/", fixture.fs.getcwd());
        }
    }

    @Test
    void mkdirAndChdir() throws IOException {
        try (ImageFixture fixture = new ImageFixture("mkdir")) {
            fixture.fs.mkdir("docs");
            fixture.fs.chdir("docs");
            assertEquals("/docs/", fixture.fs.getcwd());
        }
    }

    @Test
    void openWriteReadRoundtrip() throws IOException {
        try (ImageFixture fixture = new ImageFixture("roundtrip")) {
            fixture.fs.mkdir("docs");
            fixture.fs.chdir("docs");

            FileHandle out = fixture.fs.open("note.txt", "w");
            byte[] payload = "hello filefs".getBytes();
            assertEquals(payload.length, fixture.fs.write(out, payload, 0, payload.length));
            fixture.fs.close(out);

            FileHandle in = fixture.fs.open("note.txt", "r");
            assertTrue(fixture.fs.seek(in, 0L, SeekWhence.END));
            assertEquals(payload.length, fixture.fs.tell(in));
            fixture.fs.rewind(in);

            byte[] read = new byte[64];
            int n = fixture.fs.read(in, read, 0, read.length);
            fixture.fs.close(in);

            assertEquals("hello filefs", new String(read, 0, n));
        }
    }

    @Test
    void copyRenameAndRemove() throws IOException {
        try (ImageFixture fixture = new ImageFixture("copy")) {
            FileHandle out = fixture.fs.open("orig.txt", "w");
            byte[] payload = "copy me".getBytes();
            assertEquals(payload.length, fixture.fs.write(out, payload, 0, payload.length));
            fixture.fs.close(out);

            fixture.fs.copyFile("orig.txt", "copy.txt");
            fixture.fs.rename("copy.txt", "renamed.txt");
            assertTrue(fixture.fs.fileExists("renamed.txt"));
            fixture.fs.removeFile("renamed.txt");
            assertFalse(fixture.fs.fileExists("renamed.txt"));
        }
    }

    @Test
    void openDirListsDocs() throws IOException {
        try (ImageFixture fixture = new ImageFixture("readdir")) {
            fixture.fs.mkdir("docs");
            DirectoryHandle dir = fixture.fs.openDir("/");
            assertNotNull(dir);
            assertEquals("/", dir.absolutePath());

            boolean foundDocs = false;
            while (true) {
                DirEntry entry = fixture.fs.readDir(dir);
                if (entry == null) {
                    break;
                }
                if ("docs".equals(entry.name()) && entry.type() == FileType.DIR) {
                    foundDocs = true;
                }
            }
            fixture.fs.closeDir(dir);
            assertTrue(foundDocs);
        }
    }

    @Test
    void beginCommitCreatesFile() throws IOException {
        try (ImageFixture fixture = new ImageFixture("txn")) {
            assertTrue(fixture.fs.begin());
            FileHandle out = fixture.fs.open("txn.txt", "w");
            byte[] payload = {'x'};
            assertEquals(1, fixture.fs.write(out, payload, 0, 1));
            fixture.fs.close(out);
            assertTrue(fixture.fs.commit());
            assertTrue(fixture.fs.fileExists("txn.txt"));
        }
    }

    private static final class ImageFixture implements AutoCloseable {
        final Path imagePath;
        final FileSystem fs = new FileSystem();

        ImageFixture(String name) throws IOException {
            imagePath = Files.createTempFile("filefs-java-" + name + "-", ".ffs");
            Files.deleteIfExists(imagePath);
            FileSystem.mkfs(imagePath);
            fs.mount(imagePath);
        }

        @Override
        public void close() throws IOException {
            fs.umount();
            Files.deleteIfExists(imagePath);
            Files.deleteIfExists(Path.of(imagePath.toString() + "-j"));
        }
    }
}
