namespace FileFS;

public sealed partial class FileSystem
{
    private uint GenerateBlockIndex()
    {
        Span<byte> block = stackalloc byte[FileSystemInternal.BlockSize];

        if (_tmp.NewUnusedBlockHead > 0)
        {
            var blockIndex = _tmp.NewUnusedBlockHead;
            if (!ReadBlock(blockIndex, block))
            {
                return 0;
            }

            _tmp.NewUnusedBlockHead = FileSystemUtil.ReadUInt32(block[4..8]);
            return blockIndex;
        }

        var newBlockIndex = _tmp.NewTotalBlockSize;
        var addIndex = newBlockIndex - _tmp.TotalBlockSize;
        block.Clear();

        var addStream = _tmp.AddStream ?? throw Error("Transaction add stream is unavailable.");
        FileSystemUtil.SetPosition(addStream, (long)addIndex * (4 + FileSystemInternal.BlockSize));

        Span<byte> b4 = stackalloc byte[4];
        FileSystemUtil.WriteUInt32(b4, newBlockIndex);
        addStream.Write(b4);
        addStream.Write(block);
        _tmp.NewTotalBlockSize++;
        return newBlockIndex;
    }

    private bool ReadBlock(uint blockIndex, Span<byte> block)
    {
        var mainPosition = (long)blockIndex * FileSystemInternal.BlockSize;
        FileSystemUtil.SetPosition(Stream, mainPosition);

        Span<byte> b4 = stackalloc byte[4];
        if (!FileSystemUtil.ReadExact(Stream, b4))
        {
            if (_tmp.State == 0 || blockIndex < _tmp.TotalBlockSize || _tmp.AddStream is null)
            {
                return false;
            }

            var addIndex = blockIndex - _tmp.TotalBlockSize;
            FileSystemUtil.SetPosition(_tmp.AddStream, (long)addIndex * (4 + FileSystemInternal.BlockSize) + 4);
            return FileSystemUtil.ReadExact(_tmp.AddStream, block);
        }

        if (_tmp.State == 0 || _tmp.CopyStream is null)
        {
            b4.CopyTo(block);
            return FileSystemUtil.ReadExact(Stream, block[4..]);
        }

        var cpIndex = FileSystemUtil.ReadUInt32(b4);
        var copyPosition = (long)cpIndex * (4 + FileSystemInternal.BlockSize);
        FileSystemUtil.SetPosition(_tmp.CopyStream, copyPosition);

        Span<byte> copyIndexBytes = stackalloc byte[4];
        if (!FileSystemUtil.ReadExact(_tmp.CopyStream, copyIndexBytes))
        {
            b4.CopyTo(block);
            FileSystemUtil.SetPosition(Stream, mainPosition + 4);
            return FileSystemUtil.ReadExact(Stream, block[4..]);
        }

        var originalIndex = FileSystemUtil.ReadUInt32(copyIndexBytes);
        if (originalIndex != blockIndex)
        {
            b4.CopyTo(block);
            FileSystemUtil.SetPosition(Stream, mainPosition + 4);
            return FileSystemUtil.ReadExact(Stream, block[4..]);
        }

        return FileSystemUtil.ReadExact(_tmp.CopyStream, block);
    }

    private bool WriteBlock(uint blockIndex, ReadOnlySpan<byte> block)
    {
        if (_tmp.State == 0 || _tmp.CopyStream is null || _tmp.AddStream is null)
        {
            return false;
        }

        var mainPosition = (long)blockIndex * FileSystemInternal.BlockSize;
        FileSystemUtil.SetPosition(Stream, mainPosition);

        Span<byte> b4 = stackalloc byte[4];
        if (!FileSystemUtil.ReadExact(Stream, b4))
        {
            if (blockIndex < _tmp.TotalBlockSize)
            {
                return false;
            }

            var addIndex = blockIndex - _tmp.TotalBlockSize;
            FileSystemUtil.SetPosition(_tmp.AddStream, (long)addIndex * (4 + FileSystemInternal.BlockSize) + 4);
            _tmp.AddStream.Write(block);
            return true;
        }

        var cpIndex = FileSystemUtil.ReadUInt32(b4);
        var copyPosition = (long)cpIndex * (4 + FileSystemInternal.BlockSize);
        FileSystemUtil.SetPosition(_tmp.CopyStream, copyPosition);

        Span<byte> copyIndexBytes = stackalloc byte[4];
        if (!FileSystemUtil.ReadExact(_tmp.CopyStream, copyIndexBytes) || FileSystemUtil.ReadUInt32(copyIndexBytes) != blockIndex)
        {
            cpIndex = _tmp.CopySize;
            copyPosition = (long)cpIndex * (4 + FileSystemInternal.BlockSize);
            FileSystemUtil.SetPosition(_tmp.CopyStream, copyPosition);
            FileSystemUtil.WriteUInt32(copyIndexBytes, blockIndex);
            _tmp.CopyStream.Write(copyIndexBytes);
            _tmp.CopyStream.Write(block);

            FileSystemUtil.SetPosition(Stream, mainPosition);
            FileSystemUtil.WriteUInt32(copyIndexBytes, cpIndex);
            Stream.Write(copyIndexBytes);
            _tmp.CopySize++;
            return true;
        }

        FileSystemUtil.SetPosition(_tmp.CopyStream, copyPosition + 4);
        _tmp.CopyStream.Write(block);
        return true;
    }

    private bool RemoveBlock(uint blockIndex)
    {
        if (_tmp.State == 0 || _tmp.CopyStream is null || _tmp.AddStream is null)
        {
            return false;
        }

        var mainPosition = (long)blockIndex * FileSystemInternal.BlockSize;
        FileSystemUtil.SetPosition(Stream, mainPosition);

        Span<byte> b4 = stackalloc byte[4];
        if (!FileSystemUtil.ReadExact(Stream, b4))
        {
            if (blockIndex < _tmp.TotalBlockSize)
            {
                return false;
            }

            var addIndex = blockIndex - _tmp.TotalBlockSize;
            FileSystemUtil.SetPosition(_tmp.AddStream, (long)addIndex * (4 + FileSystemInternal.BlockSize) + 8);
            FileSystemUtil.WriteUInt32(b4, _tmp.NewUnusedBlockHead);
            _tmp.AddStream.Write(b4);
            _tmp.NewUnusedBlockHead = blockIndex;
            return true;
        }

        var cpIndex = FileSystemUtil.ReadUInt32(b4);
        var copyPosition = (long)cpIndex * (4 + FileSystemInternal.BlockSize);
        FileSystemUtil.SetPosition(_tmp.CopyStream, copyPosition);

        Span<byte> copyIndexBytes = stackalloc byte[4];
        if (!FileSystemUtil.ReadExact(_tmp.CopyStream, copyIndexBytes) || FileSystemUtil.ReadUInt32(copyIndexBytes) != blockIndex)
        {
            cpIndex = _tmp.CopySize;
            copyPosition = (long)cpIndex * (4 + FileSystemInternal.BlockSize);
            FileSystemUtil.SetPosition(_tmp.CopyStream, copyPosition);
            FileSystemUtil.WriteUInt32(copyIndexBytes, blockIndex);
            _tmp.CopyStream.Write(copyIndexBytes);

            var freeBlock = new byte[FileSystemInternal.BlockSize];
            FileSystemUtil.WriteUInt32(freeBlock.AsSpan(4, 4), _tmp.NewUnusedBlockHead);
            _tmp.CopyStream.Write(freeBlock);

            FileSystemUtil.SetPosition(Stream, mainPosition);
            FileSystemUtil.WriteUInt32(copyIndexBytes, cpIndex);
            Stream.Write(copyIndexBytes);
            _tmp.CopySize++;
            _tmp.NewUnusedBlockHead = blockIndex;
            return true;
        }

        FileSystemUtil.SetPosition(_tmp.CopyStream, copyPosition + 8);
        FileSystemUtil.WriteUInt32(copyIndexBytes, _tmp.NewUnusedBlockHead);
        _tmp.CopyStream.Write(copyIndexBytes);
        _tmp.NewUnusedBlockHead = blockIndex;
        return true;
    }

    private uint FindPathBlockIndex(uint blockIndex, string pathName)
    {
        var block = new byte[FileSystemInternal.BlockSize];
        if (!ReadBlock(blockIndex, block))
        {
            return 0;
        }

        var stopBlockIndex = FileSystemUtil.ReadUInt32(block.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4));
        var offset = FileSystemUtil.ReadUInt16(block.AsSpan(FileSystemInternal.BlockOffset, 2));

        var index = blockIndex;
        while (true)
        {
            var k = FileSystemInternal.BlockHead;
            for (var i = 0; i < FileSystemInternal.BlockItemMaxCount; i++)
            {
                var state = block[k++];
                var isFile = (state & 0x01) == 0x01;
                if (isFile)
                {
                    k += 24;
                    if (index == stopBlockIndex && k + 1 >= offset)
                    {
                        return 0;
                    }

                    continue;
                }

                var entryName = FileSystemUtil.FixedNameToString(block.AsSpan(k, FileSystemInternal.BlockNameMaxSize));
                k += FileSystemInternal.BlockNameMaxSize;
                if (!string.Equals(entryName, pathName, StringComparison.Ordinal))
                {
                    k += 10;
                    if (index == stopBlockIndex && k + 1 >= offset)
                    {
                        return 0;
                    }

                    continue;
                }

                return FileSystemUtil.ReadUInt32(block.AsSpan(k, 4));
            }

            index = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
            if (index == 0 || !ReadBlock(index, block))
            {
                return 0;
            }
        }
    }
}
