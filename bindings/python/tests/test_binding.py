from unittest import TestCase

import filefs
import os
import logging
import unittest

class TestFileFS(TestCase):
    def setUp(self):
        logging.basicConfig(level=logging.INFO)
        self.logger = logging.getLogger(__name__)
        self.ffs = filefs.create()
        self.test_file = os.path.abspath("test.ffs")
        self.logger.info(f"Creating filesystem at: {self.test_file}")
        filefs.mkfs(self.test_file)
        filefs.mount(self.ffs, self.test_file)

    def tearDown(self):
        if filefs.ismount(self.ffs):
            self.logger.info(f"Unmounting filesystem: {self.test_file}")
            filefs.umount(self.ffs)
        # filefs.destroy(self.ffs)
        # try:
        #     os.remove(self.test_file)
        #     self.logger.info(f"Removed filesystem file: {self.test_file}")
        # except:
        #     self.logger.warning(f"Failed to remove filesystem file: {self.test_file}")
        #     pass

    def test_file_operations(self):
        # Test file write and read
        filepath = "/test.txt"
        self.logger.info(f"Writing to file: {filepath}")
        f = filefs.fopen(self.ffs, filepath, "w")
        data = b"Hello World"
        filefs.fwrite(self.ffs, data, 1, len(data), f)
        filefs.fclose(self.ffs, f)
        self.logger.info(f"Wrote content: {data}")

        self.logger.info(f"Reading from file: {filepath}")
        f = filefs.fopen(self.ffs, filepath, "r")
        content = filefs.fread(self.ffs, 1, len(data), f)
        filefs.fclose(self.ffs, f)
        self.logger.info(f"Read content: {content}")
        self.assertEqual(content, data)

        # Test file seek
        f = filefs.fopen(self.ffs, filepath, "r")
        filefs.fseek(self.ffs, f, 6, 0)
        content = filefs.fread(self.ffs, 1, 5, f)
        self.logger.info(f"After seek, read content: {content}")
        self.assertEqual(content, b"World")
        
        # Test ftell and rewind
        pos = filefs.ftell(self.ffs, f)
        self.logger.info(f"Current position: {pos}")
        filefs.rewind(self.ffs, f)
        pos = filefs.ftell(self.ffs, f)
        self.logger.info(f"Position after rewind: {pos}")
        filefs.fclose(self.ffs, f)

    def test_directory_operations(self):
        # Test mkdir and chdir
        dirpath = "/testdir"
        self.logger.info(f"Creating directory: {dirpath}")
        filefs.mkdir(self.ffs, dirpath)
        filefs.chdir(self.ffs, dirpath)
        cwd = filefs.getcwd(self.ffs)
        self.logger.info(f"Current working directory: {cwd}")

        # Test file operations in directory
        filepath = "test.txt"
        self.logger.info(f"Creating file in directory: {cwd}/{filepath}")
        f = filefs.fopen(self.ffs, filepath, "w")
        filefs.fwrite(self.ffs, b"test", 1, 4, f)
        filefs.fclose(self.ffs, f)

        # Test directory listing
        self.logger.info(f"Listing directory contents: {cwd}")
        dir_handle = filefs.opendir(self.ffs, ".")
        entry = filefs.readdir(self.ffs, dir_handle)
        while entry:
            self.logger.info(f"Found entry: {entry['name']}")
            entry = filefs.readdir(self.ffs, dir_handle)

        # Test file move and copy
        self.logger.info(f"Copying and moving files in: {cwd}")
        filefs.copy(self.ffs, "test.txt", "test2.txt")
        filefs.move(self.ffs, "test2.txt", "test3.txt")

        # Test file removal
        self.logger.info(f"Removing file: {cwd}/{filepath}")
        filefs.remove(self.ffs, filepath)

        # Test directory removal
        filefs.chdir(self.ffs, "..")
        self.logger.info(f"Removing directory: {dirpath}")
        filefs.rmdir(self.ffs, dirpath)

    def test_advanced_operations(self):
        # Test file truncate
        filepath = "/truncate.txt"
        self.logger.info(f"Creating and truncating file: {filepath}")
        f = filefs.fopen(self.ffs, filepath, "w")
        filefs.fwrite(self.ffs, b"Hello World", 1, 11, f) 
        filefs.ftruncate(self.ffs, f, 5)
        filefs.fclose(self.ffs, f)
        
        # Verify truncated content
        self.logger.info(f"Verifying truncated content of: {filepath}")
        f = filefs.fopen(self.ffs, filepath, "r")
        content = filefs.fread(self.ffs, 1, 11, f)
        self.assertEqual(content, b"Hello")
        filefs.fclose(self.ffs, f)

        # Test nested directories
        self.logger.info("Creating nested directory structure")
        filefs.mkdir(self.ffs, "/dir1")
        filefs.mkdir(self.ffs, "/dir1/dir2") 
        filefs.mkdir(self.ffs, "/dir1/dir2/dir3")

        # Test file access in nested dirs
        self.logger.info("Testing file access in nested directories")
        f = filefs.fopen(self.ffs, "/dir1/dir2/test.txt", "w")
        filefs.fwrite(self.ffs, b"test", 1, 4, f)
        filefs.fclose(self.ffs, f)

        # Test directory traversal
        self.logger.info("Testing directory traversal")
        filefs.chdir(self.ffs, "/dir1/dir2/dir3")
        cwd = filefs.getcwd(self.ffs)
        self.logger.info(f"Current working directory: {cwd}")
        self.assertEqual(cwd, "/dir1/dir2/dir3")
        filefs.chdir(self.ffs, "../..")
        cwd = filefs.getcwd(self.ffs)
        self.logger.info(f"After going up two levels: {cwd}")
        self.assertEqual(cwd, "/dir1")

        # Clean up
        self.logger.info("Cleaning up test directories and files")
        filefs.remove(self.ffs, "/dir1/dir2/test.txt")
        filefs.rmdir(self.ffs, "/dir1/dir2/dir3")
        filefs.rmdir(self.ffs, "/dir1/dir2")
        filefs.rmdir(self.ffs, "/dir1")

if __name__ == '__main__':
    unittest.main()