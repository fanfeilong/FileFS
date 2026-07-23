namespace FileFS;

public sealed partial class FileSystem
{
    public int Read(FileHandle file, Span<byte> buffer)
    {
        EnsureMounted();
        ArgumentNullException.ThrowIfNull(file);

        if (file.IsClosed)
        {
            throw Error("File handle is closed.");
        }

        if (file.Mode is 1 or 2)
        {
            throw Error("File handle is not readable.");
        }

        if (file.PosBlockIndex == 0 || buffer.Length == 0)
        {
            return 0;
        }

        var totalRead = 0;
        var block = new byte[FileSystemInternal.BlockSize];
        var blockIndex = file.PosBlockIndex;

        while (totalRead < buffer.Length)
        {
            if (!ReadBlock(blockIndex, block))
            {
                return totalRead;
            }

            var nextIndex = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
            if (file.PosOffset == FileSystemInternal.BlockSize)
            {
                if (nextIndex == 0)
                {
                    return totalRead;
                }

                blockIndex = nextIndex;
                file.PosBlockIndex = blockIndex;
                file.PosOffset = FileSystemInternal.BlockHead;
                continue;
            }

            if (blockIndex == file.FileStopBlockIndex)
            {
                var remainingInFile = file.FileOffset - file.PosOffset;
                if (remainingInFile <= 0)
                {
                    return totalRead;
                }

                var count = Math.Min(buffer.Length - totalRead, remainingInFile);
                block.AsSpan(file.PosOffset, count).CopyTo(buffer[totalRead..]);
                totalRead += count;
                file.PosOffset += (ushort)count;
                file.Pos += (ulong)count;
                file.PosBlockIndex = blockIndex;
                return totalRead;
            }

            var remainingInBlock = FileSystemInternal.BlockSize - file.PosOffset;
            if (remainingInBlock <= 0)
            {
                return totalRead;
            }

            var toCopy = Math.Min(buffer.Length - totalRead, remainingInBlock);
            block.AsSpan(file.PosOffset, toCopy).CopyTo(buffer[totalRead..]);
            totalRead += toCopy;
            file.PosOffset += (ushort)toCopy;
            file.Pos += (ulong)toCopy;
            file.PosBlockIndex = blockIndex;

            if (file.PosOffset == FileSystemInternal.BlockSize && nextIndex != 0)
            {
                blockIndex = nextIndex;
            }
        }

        return totalRead;
    }

    public int Write(FileHandle file, ReadOnlySpan<byte> buffer)
    {
        EnsureMounted();
        ArgumentNullException.ThrowIfNull(file);

        if (file.IsClosed)
        {
            throw Error("File handle is closed.");
        }

        if (file.Mode == 0)
        {
            throw Error("File handle is not writable.");
        }

        if (buffer.Length == 0)
        {
            return 0;
        }

        var autoCommit = _tmp.State == 0;
        if (autoCommit && !StartTransaction(1))
        {
            throw Error("Unable to start implicit FileFS transaction.");
        }

        var written = 0;
        var posBlock = new byte[FileSystemInternal.BlockSize];
        var dirBlock = new byte[FileSystemInternal.BlockSize];
        uint nextBlockIndex;

        try
        {
            if (file.PosBlockIndex == 0)
            {
                var newBlockIndex = GenerateBlockIndex();
                if (newBlockIndex == 0)
                {
                    throw Error("Unable to allocate FileFS data block.");
                }

                Array.Clear(posBlock);
                if (!WriteBlock(newBlockIndex, posBlock))
                {
                    throw Error("Unable to initialize FileFS data block.");
                }

                if (!ReadBlock(file.DirBlockIndex, dirBlock))
                {
                    throw Error("Unable to read FileFS directory entry.");
                }

                FileSystemUtil.WriteUInt32(dirBlock.AsSpan(file.DirOffset - 10, 4), newBlockIndex);
                FileSystemUtil.WriteUInt32(dirBlock.AsSpan(file.DirOffset - 6, 4), newBlockIndex);
                FileSystemUtil.WriteUInt16(dirBlock.AsSpan(file.DirOffset - 2, 2), FileSystemInternal.BlockHead);

                file.FileStartBlockIndex = newBlockIndex;
                file.FileStopBlockIndex = newBlockIndex;
                file.FileOffset = 0;
                file.PosBlockIndex = newBlockIndex;
                file.PosOffset = FileSystemInternal.BlockHead;
                file.Pos = 0;

                if (!WriteBlock(file.DirBlockIndex, dirBlock))
                {
                    throw Error("Unable to update FileFS directory entry.");
                }

                nextBlockIndex = 0;
            }
            else
            {
                if (!ReadBlock(file.PosBlockIndex, posBlock))
                {
                    throw Error("Unable to read FileFS data block.");
                }

                nextBlockIndex = FileSystemUtil.ReadUInt32(posBlock.AsSpan(4, 4));
            }

            while (written < buffer.Length)
            {
                var extendedWithNewBlock = false;

                if (file.PosOffset == FileSystemInternal.BlockSize)
                {
                    if (nextBlockIndex == 0)
                    {
                        var newBlockIndex = GenerateBlockIndex();
                        if (newBlockIndex == 0)
                        {
                            throw Error("Unable to allocate FileFS data block.");
                        }

                        var newBlock = new byte[FileSystemInternal.BlockSize];
                        FileSystemUtil.WriteUInt32(newBlock.AsSpan(8, 4), file.PosBlockIndex);
                        FileSystemUtil.WriteUInt32(posBlock.AsSpan(4, 4), newBlockIndex);

                        if (!WriteBlock(file.PosBlockIndex, posBlock))
                        {
                            throw Error("Unable to link FileFS data block.");
                        }

                        file.PosBlockIndex = newBlockIndex;
                        file.PosOffset = FileSystemInternal.BlockHead;
                        posBlock = newBlock;
                        nextBlockIndex = 0;
                        extendedWithNewBlock = true;
                    }
                    else
                    {
                        var currentIndex = nextBlockIndex;
                        if (!ReadBlock(currentIndex, posBlock))
                        {
                            throw Error("Unable to read next FileFS data block.");
                        }

                        nextBlockIndex = FileSystemUtil.ReadUInt32(posBlock.AsSpan(4, 4));
                        file.PosBlockIndex = currentIndex;
                        file.PosOffset = FileSystemInternal.BlockHead;
                    }
                }

                var available = FileSystemInternal.BlockSize - file.PosOffset;
                var count = Math.Min(buffer.Length - written, available);
                buffer.Slice(written, count).CopyTo(posBlock.AsSpan(file.PosOffset, count));
                written += count;

                if (!WriteBlock(file.PosBlockIndex, posBlock))
                {
                    throw Error("Unable to write FileFS data block.");
                }

                file.PosOffset += (ushort)count;
                file.Pos += (ulong)count;

                var extended =
                    extendedWithNewBlock ||
                    file.FileStopBlockIndex == 0 ||
                    (file.PosBlockIndex == file.FileStopBlockIndex && file.PosOffset > file.FileOffset);

                if (extended)
                {
                    if (!ReadBlock(file.DirBlockIndex, dirBlock))
                    {
                        throw Error("Unable to refresh FileFS directory entry.");
                    }

                    file.FileStopBlockIndex = file.PosBlockIndex;
                    file.FileOffset = file.PosOffset;
                    FileSystemUtil.WriteUInt32(dirBlock.AsSpan(file.DirOffset - 6, 4), file.PosBlockIndex);
                    FileSystemUtil.WriteUInt16(dirBlock.AsSpan(file.DirOffset - 2, 2), file.PosOffset);

                    if (!WriteBlock(file.DirBlockIndex, dirBlock))
                    {
                        throw Error("Unable to persist FileFS directory entry.");
                    }
                }
            }

            if (autoCommit)
            {
                Commit();
            }

            return written;
        }
        catch
        {
            if (autoCommit)
            {
                StopTransaction();
            }

            throw;
        }
    }

    public void Close(FileHandle file)
    {
        ArgumentNullException.ThrowIfNull(file);
    }

    public bool Seek(FileHandle file, long offset, SeekWhence whence)
    {
        EnsureMounted();
        ArgumentNullException.ThrowIfNull(file);

        if (file.IsClosed || file.PosBlockIndex == 0 || file.FileStartBlockIndex == 0)
        {
            return false;
        }

        var length = GetFileLength(file);
        long target;
        switch (whence)
        {
            case SeekWhence.Set:
                if (offset < 0)
                {
                    return false;
                }

                target = offset;
                break;
            case SeekWhence.Cur:
                target = (long)file.Pos + offset;
                break;
            case SeekWhence.End:
                if (offset > 0)
                {
                    return false;
                }

                target = length + offset;
                break;
            default:
                return false;
        }

        if (target < 0)
        {
            target = 0;
        }
        else if (target > length)
        {
            target = length;
        }

        var blockIndex = file.FileStartBlockIndex;
        var blockOffset = FileSystemInternal.BlockHead;
        if (target == 0)
        {
            file.PosBlockIndex = blockIndex;
            file.PosOffset = (ushort)blockOffset;
            file.Pos = 0;
            return true;
        }

        var remaining = target;
        var block = new byte[FileSystemInternal.BlockSize];
        while (true)
        {
            var blockSize = blockIndex == file.FileStopBlockIndex ? file.FileOffset : FileSystemInternal.BlockSize;
            var available = blockSize - blockOffset;
            if (remaining <= available)
            {
                file.PosBlockIndex = blockIndex;
                file.PosOffset = (ushort)(blockOffset + remaining);
                file.Pos = (ulong)target;
                return true;
            }

            remaining -= available;
            if (blockIndex == file.FileStopBlockIndex)
            {
                file.PosBlockIndex = blockIndex;
                file.PosOffset = file.FileOffset;
                file.Pos = (ulong)length;
                return true;
            }

            if (!ReadBlock(blockIndex, block))
            {
                return false;
            }

            blockIndex = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
            if (blockIndex == 0)
            {
                file.PosBlockIndex = file.FileStopBlockIndex;
                file.PosOffset = file.FileOffset;
                file.Pos = (ulong)length;
                return true;
            }

            blockOffset = FileSystemInternal.BlockHead;
        }
    }

    public long Tell(FileHandle file)
    {
        EnsureMounted();
        ArgumentNullException.ThrowIfNull(file);
        return (long)file.Pos;
    }

    public void Rewind(FileHandle file)
    {
        _ = Seek(file, 0, SeekWhence.Set);
    }

    private long GetFileLength(FileHandle file)
    {
        if (file.FileStartBlockIndex == 0)
        {
            return 0;
        }

        var block = new byte[FileSystemInternal.BlockSize];
        var length = 0L;
        var index = file.FileStartBlockIndex;
        while (index != 0)
        {
            if (index == file.FileStopBlockIndex)
            {
                length += file.FileOffset - FileSystemInternal.BlockHead;
                break;
            }

            length += FileSystemInternal.BlockSize - FileSystemInternal.BlockHead;
            if (!ReadBlock(index, block))
            {
                break;
            }

            index = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
        }

        return length;
    }
}
