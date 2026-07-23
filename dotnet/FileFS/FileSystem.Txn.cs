using System.IO;

namespace FileFS;

public sealed partial class FileSystem
{
    public bool Begin()
    {
        EnsureMounted();

        if (_tmp.CopyStream is not null)
        {
            Rollback();
        }

        return StartTransaction(2);
    }

    public bool Commit()
    {
        EnsureMounted();

        if (_tmp.CopyStream is null || _tmp.AddStream is null)
        {
            return true;
        }

        using (var journal = new FileStream(
                   _journalPath,
                   FileMode.Create,
                   FileAccess.ReadWrite,
                   FileShare.Read,
                   4096,
                   FileOptions.RandomAccess))
        {
            Span<byte> state = stackalloc byte[1];
            state[0] = 0;
            journal.Write(state);

            var entry = new byte[4 + FileSystemInternal.BlockSize];

            if (_tmp.TotalBlockSize != _tmp.NewTotalBlockSize || _tmp.UnusedBlockHead != _tmp.NewUnusedBlockHead)
            {
                entry.AsSpan().Clear();
                FileSystemInternal.MagicNumber.CopyTo(entry.AsSpan(4, 4));
                FileSystemUtil.WriteUInt32(entry.AsSpan(8, 4), _tmp.NewTotalBlockSize);
                FileSystemUtil.WriteUInt32(entry.AsSpan(12, 4), _tmp.NewUnusedBlockHead);
                journal.Write(entry);
            }

            FileSystemUtil.Rewind(_tmp.CopyStream);
            while (FileSystemUtil.ReadExact(_tmp.CopyStream, entry))
            {
                journal.Write(entry);
            }

            FileSystemUtil.Rewind(_tmp.AddStream);
            while (FileSystemUtil.ReadExact(_tmp.AddStream, entry))
            {
                journal.Write(entry);
            }

            FileSystemUtil.SetPosition(journal, 0);
            state[0] = 0xff;
            journal.Write(state);
            FileSystemUtil.Flush(journal);
        }

        using (var journal = new FileStream(
                   _journalPath,
                   FileMode.Open,
                   FileAccess.Read,
                   FileShare.Read,
                   4096,
                   FileOptions.RandomAccess))
        {
            Span<byte> state = stackalloc byte[1];
            if (!FileSystemUtil.ReadExact(journal, state))
            {
                StopTransaction();
                throw Error("Unable to read FileFS journal state.");
            }

            var entry = new byte[4 + FileSystemInternal.BlockSize];
            while (FileSystemUtil.ReadExact(journal, entry))
            {
                var blockIndex = FileSystemUtil.ReadUInt32(entry.AsSpan(0, 4));
                FileSystemUtil.SetPosition(Stream, (long)blockIndex * FileSystemInternal.BlockSize);
                Stream.Write(entry.AsSpan(4, FileSystemInternal.BlockSize));
            }
        }

        FileSystemUtil.Flush(Stream);
        if (File.Exists(_journalPath))
        {
            File.Delete(_journalPath);
        }

        _pwd = _tmp.Pwd;
        _pwdBlockIndex = _tmp.PwdBlockIndex;

        StopTransaction();
        return true;
    }

    public void Rollback()
    {
        if (!IsMounted)
        {
            return;
        }

        if (!string.IsNullOrEmpty(_journalPath) && File.Exists(_journalPath))
        {
            File.Delete(_journalPath);
        }

        if (_tmp.CopyStream is null)
        {
            return;
        }

        StopTransaction();
    }

    private bool StartTransaction(byte state)
    {
        if (state == 0)
        {
            return false;
        }

        if (_tmp.State != 0)
        {
            StopTransaction();
        }

        var block = new byte[12];
        FileSystemUtil.Rewind(Stream);
        if (!FileSystemUtil.ReadExact(Stream, block))
        {
            return false;
        }

        _tmp.TotalBlockSize = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
        _tmp.UnusedBlockHead = FileSystemUtil.ReadUInt32(block.AsSpan(8, 4));
        _tmp.NewTotalBlockSize = _tmp.TotalBlockSize;
        _tmp.NewUnusedBlockHead = _tmp.UnusedBlockHead;

        var copyPath = Path.GetTempFileName();
        var addPath = Path.GetTempFileName();

        _tmp.CopyStream = new FileStream(copyPath, FileMode.Create, FileAccess.ReadWrite, FileShare.Read, 4096, FileOptions.RandomAccess);
        _tmp.CopyPath = copyPath;
        _tmp.AddStream = new FileStream(addPath, FileMode.Create, FileAccess.ReadWrite, FileShare.Read, 4096, FileOptions.RandomAccess);
        _tmp.AddPath = addPath;
        _tmp.Pwd = _pwd;
        _tmp.PwdBlockIndex = _pwdBlockIndex;
        _tmp.CopySize = 0;
        _tmp.State = state;
        return true;
    }

    private void StopTransaction()
    {
        _tmp.CopyStream?.Dispose();
        _tmp.CopyStream = null;
        if (!string.IsNullOrEmpty(_tmp.CopyPath) && File.Exists(_tmp.CopyPath))
        {
            File.Delete(_tmp.CopyPath);
        }

        _tmp.CopyPath = string.Empty;

        _tmp.AddStream?.Dispose();
        _tmp.AddStream = null;
        if (!string.IsNullOrEmpty(_tmp.AddPath) && File.Exists(_tmp.AddPath))
        {
            File.Delete(_tmp.AddPath);
        }

        _tmp.AddPath = string.Empty;
        _tmp.CopySize = 0;
        _tmp.State = 0;
    }
}
