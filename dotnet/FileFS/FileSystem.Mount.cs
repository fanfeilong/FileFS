using System.IO;

namespace FileFS;

public sealed partial class FileSystem
{
    public static void Mkfs(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);

        using var stream = new FileStream(
            path,
            FileMode.Create,
            FileAccess.ReadWrite,
            FileShare.Read,
            4096,
            FileOptions.RandomAccess);

        Span<byte> block = stackalloc byte[FileSystemInternal.BlockSize];

        block.Clear();
        FileSystemInternal.MagicNumber.CopyTo(block);
        FileSystemUtil.WriteUInt32(block[4..8], 2);
        stream.Write(block);

        block.Clear();
        var k = FileSystemInternal.BlockHead;

        block[k++] = 0;
        FileSystemUtil.CopyName(block.Slice(k, FileSystemInternal.BlockNameMaxSize), ".");
        k += FileSystemInternal.BlockNameMaxSize;
        FileSystemUtil.WriteUInt32(block.Slice(k, 4), 1);
        k += 4;
        FileSystemUtil.WriteUInt32(block.Slice(k, 4), 1);
        k += 4;
        FileSystemUtil.WriteUInt16(block.Slice(k, 2), 62);
        k += 2;

        block[k++] = 0;
        FileSystemUtil.CopyName(block.Slice(k, FileSystemInternal.BlockNameMaxSize), "..");
        stream.Write(block);

        FileSystemUtil.Flush(stream);

        var journalPath = path + "-j";
        if (File.Exists(journalPath))
        {
            File.Delete(journalPath);
        }
    }

    public void Mount(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);

        Umount();

        var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.ReadWrite,
            FileShare.Read,
            4096,
            FileOptions.RandomAccess);

        var block = new byte[FileSystemInternal.BlockSize];

        if (!FileSystemUtil.ReadExact(stream, block))
        {
            stream.Dispose();
            throw Error("Unable to read FileFS superblock.");
        }

        if (!block.AsSpan(0, 4).SequenceEqual(FileSystemInternal.MagicNumber))
        {
            stream.Dispose();
            throw Error("Invalid FileFS magic number.");
        }

        var blockCount = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
        if (blockCount < 2)
        {
            stream.Dispose();
            throw Error("Invalid FileFS block count.");
        }

        if (!FileSystemUtil.ReadExact(stream, block))
        {
            stream.Dispose();
            throw Error("Unable to read FileFS root directory block.");
        }

        var rootOffset = FileSystemInternal.BlockHead;
        if (block[rootOffset] != 0)
        {
            stream.Dispose();
            throw Error("Invalid FileFS root directory entry state.");
        }

        var dotName = FileSystemUtil.FixedNameToString(block.AsSpan(rootOffset + 1, FileSystemInternal.BlockNameMaxSize));
        if (!string.Equals(dotName, ".", StringComparison.Ordinal))
        {
            stream.Dispose();
            throw Error("Invalid FileFS root directory '.' entry.");
        }

        var dotDotOffset = rootOffset + 25;
        if (block[dotDotOffset] != 0)
        {
            stream.Dispose();
            throw Error("Invalid FileFS root directory parent entry state.");
        }

        var dotDotName = FileSystemUtil.FixedNameToString(block.AsSpan(dotDotOffset + 1, FileSystemInternal.BlockNameMaxSize));
        if (!string.Equals(dotDotName, "..", StringComparison.Ordinal))
        {
            stream.Dispose();
            throw Error("Invalid FileFS root directory '..' entry.");
        }

        _stream = stream;
        _path = path;
        _journalPath = path + "-j";
        _pwd = "/";
        _pwdBlockIndex = 1;
        _pwdTmp = string.Empty;

        RecoverJournal();
    }

    public void Umount()
    {
        _stream?.Dispose();
        _stream = null;
        _path = string.Empty;

        if (!string.IsNullOrEmpty(_journalPath) && File.Exists(_journalPath))
        {
            File.Delete(_journalPath);
        }

        _journalPath = string.Empty;
        StopTransaction();
        _tmp.Pwd = string.Empty;
        _tmp.PwdBlockIndex = 0;
        _pwd = string.Empty;
        _pwdBlockIndex = 0;
        _pwdTmp = string.Empty;
    }

    private void RecoverJournal()
    {
        if (string.IsNullOrEmpty(_journalPath) || !File.Exists(_journalPath))
        {
            return;
        }

        using var journal = new FileStream(
            _journalPath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            4096,
            FileOptions.RandomAccess);

        Span<byte> state = stackalloc byte[1];
        if (!FileSystemUtil.ReadExact(journal, state) || state[0] != 0xff)
        {
            journal.Dispose();
            File.Delete(_journalPath);
            return;
        }

        var entry = new byte[4 + FileSystemInternal.BlockSize];
        while (FileSystemUtil.ReadExact(journal, entry))
        {
            var blockIndex = FileSystemUtil.ReadUInt32(entry.AsSpan(0, 4));
            FileSystemUtil.SetPosition(Stream, (long)blockIndex * FileSystemInternal.BlockSize);
            Stream.Write(entry.AsSpan(4, FileSystemInternal.BlockSize));
        }

        FileSystemUtil.Flush(Stream);
        File.Delete(_journalPath);
    }
}
