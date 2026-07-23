import os
import tempfile
import unittest

import filefs


class TestFileFS(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.path = os.path.join(self._tmpdir.name, "test.ffs")
        self.ffs = filefs.create()
        self.assertTrue(filefs.mkfs(self.path))
        self.assertTrue(filefs.mount(self.ffs, self.path))
        self.assertTrue(filefs.ismount(self.ffs))

    def tearDown(self):
        if filefs.ismount(self.ffs):
            filefs.umount(self.ffs)
        filefs.destroy(self.ffs)

    def test_file_read_write_seek(self):
        path = "/test.txt"
        data = b"Hello World"

        f = filefs.fopen(self.ffs, path, "w")
        self.assertIsNotNone(f)
        written = filefs.fwrite(self.ffs, data, 1, len(data), f)
        self.assertEqual(written, len(data))
        filefs.fclose(self.ffs, f)

        self.assertTrue(filefs.file_exist(self.ffs, path))

        f = filefs.fopen(self.ffs, path, "r")
        content = filefs.fread(self.ffs, 1, len(data), f)
        filefs.fclose(self.ffs, f)
        self.assertEqual(content, data)

        f = filefs.fopen(self.ffs, path, "r")
        self.assertTrue(filefs.fseek(self.ffs, f, 6, filefs.SEEK_SET))
        content = filefs.fread(self.ffs, 1, 5, f)
        self.assertEqual(content, b"World")
        pos = filefs.ftell(self.ffs, f)
        self.assertEqual(pos, 11)
        filefs.rewind(self.ffs, f)
        self.assertEqual(filefs.ftell(self.ffs, f), 0)
        filefs.fclose(self.ffs, f)

    def test_directory_operations(self):
        self.assertEqual(filefs.mkdir(self.ffs, "/testdir"), 0)
        self.assertTrue(filefs.dir_exist(self.ffs, "/testdir"))
        self.assertTrue(filefs.chdir(self.ffs, "/testdir"))
        self.assertEqual(filefs.getcwd(self.ffs), "/testdir/")

        f = filefs.fopen(self.ffs, "note.txt", "w")
        self.assertIsNotNone(f)
        self.assertEqual(filefs.fwrite(self.ffs, b"test", 1, 4, f), 4)
        filefs.fclose(self.ffs, f)

        opened = filefs.opendir(self.ffs, ".")
        self.assertIsNotNone(opened)
        dir_handle, abs_path = opened
        self.assertTrue(abs_path.endswith("testdir/"))

        names = []
        while True:
            entry = filefs.readdir(self.ffs, dir_handle)
            if entry is None:
                break
            names.append(entry["name"])
        filefs.closedir(self.ffs, dir_handle)
        self.assertIn("note.txt", names)
        self.assertIn(".", names)
        self.assertIn("..", names)

        self.assertEqual(filefs.copy(self.ffs, "note.txt", "note2.txt"), 0)
        self.assertTrue(filefs.file_exist(self.ffs, "note2.txt"))
        self.assertEqual(filefs.rename(self.ffs, "note2.txt", "note3.txt"), 0)
        self.assertTrue(filefs.file_exist(self.ffs, "note3.txt"))
        self.assertFalse(filefs.file_exist(self.ffs, "note2.txt"))

        self.assertEqual(filefs.remove(self.ffs, "note.txt"), 0)
        self.assertEqual(filefs.remove(self.ffs, "note3.txt"), 0)
        self.assertTrue(filefs.chdir(self.ffs, "/"))
        self.assertEqual(filefs.rmdir(self.ffs, "/testdir"), 0)
        self.assertFalse(filefs.dir_exist(self.ffs, "/testdir"))

    def test_nested_dirs_and_move(self):
        self.assertEqual(filefs.mkdir(self.ffs, "/dir1"), 0)
        self.assertEqual(filefs.mkdir(self.ffs, "/dir1/dir2"), 0)
        self.assertEqual(filefs.mkdir(self.ffs, "/dir1/dir2/dir3"), 0)

        f = filefs.fopen(self.ffs, "/dir1/dir2/test.txt", "w")
        self.assertIsNotNone(f)
        self.assertEqual(filefs.fwrite(self.ffs, b"abcd", 1, 4, f), 4)
        filefs.fclose(self.ffs, f)

        self.assertTrue(filefs.chdir(self.ffs, "/dir1/dir2/dir3"))
        self.assertEqual(filefs.getcwd(self.ffs), "/dir1/dir2/dir3/")
        self.assertTrue(filefs.chdir(self.ffs, "../.."))
        self.assertEqual(filefs.getcwd(self.ffs), "/dir1/")

        self.assertEqual(filefs.mkdir(self.ffs, "/target"), 0)
        self.assertEqual(filefs.move(self.ffs, "/dir1/dir2/test.txt", "/target"), 0)
        self.assertTrue(filefs.file_exist(self.ffs, "/target/test.txt"))
        self.assertFalse(filefs.file_exist(self.ffs, "/dir1/dir2/test.txt"))

        self.assertEqual(filefs.remove(self.ffs, "/target/test.txt"), 0)
        self.assertEqual(filefs.rmdir(self.ffs, "/target"), 0)
        self.assertEqual(filefs.rmdir(self.ffs, "/dir1/dir2/dir3"), 0)
        self.assertEqual(filefs.rmdir(self.ffs, "/dir1/dir2"), 0)
        self.assertEqual(filefs.rmdir(self.ffs, "/dir1"), 0)

    def test_transaction(self):
        self.assertTrue(filefs.begin(self.ffs))
        f = filefs.fopen(self.ffs, "/txn.txt", "w")
        self.assertIsNotNone(f)
        self.assertEqual(filefs.fwrite(self.ffs, b"x", 1, 1, f), 1)
        filefs.fclose(self.ffs, f)
        self.assertTrue(filefs.commit(self.ffs))
        self.assertTrue(filefs.file_exist(self.ffs, "/txn.txt"))

        self.assertTrue(filefs.begin(self.ffs))
        f = filefs.fopen(self.ffs, "/rollback.txt", "w")
        self.assertIsNotNone(f)
        self.assertEqual(filefs.fwrite(self.ffs, b"y", 1, 1, f), 1)
        filefs.fclose(self.ffs, f)
        filefs.rollback(self.ffs)
        self.assertFalse(filefs.file_exist(self.ffs, "/rollback.txt"))

    def test_append_and_constants(self):
        f = filefs.fopen(self.ffs, "/a.txt", "w")
        filefs.fwrite(self.ffs, b"ab", 1, 2, f)
        filefs.fclose(self.ffs, f)

        f = filefs.fopen(self.ffs, "/a.txt", "a")
        filefs.fwrite(self.ffs, b"cd", 1, 2, f)
        filefs.fclose(self.ffs, f)

        f = filefs.fopen(self.ffs, "/a.txt", "r")
        content = filefs.fread(self.ffs, 1, 10, f)
        filefs.fclose(self.ffs, f)
        self.assertEqual(content, b"abcd")

        self.assertEqual(filefs.DT_FILE, 0)
        self.assertEqual(filefs.DT_DIR, 1)
        self.assertEqual(filefs.SEEK_SET, 0)


if __name__ == "__main__":
    unittest.main()
