namespace FileFS;

public sealed partial class FileSystem
{
    public FileHandle Open(string path, string mode)
    {
        EnsureMounted();
        ArgumentException.ThrowIfNullOrEmpty(path);
        ArgumentException.ThrowIfNullOrEmpty(mode);

        var byteMode = ParseMode(mode);

        uint blockIndex;
        var start = 0;
        if (path[0] == '/')
        {
            blockIndex = 1;
            start = 1;
        }
        else
        {
            blockIndex = CurrentPwdBlockIndex;
        }

        Span<char> segment = stackalloc char[FileSystemInternal.BlockNameMaxSize + 1];
        var segmentLength = 0;
        for (var i = start; i < path.Length; i++)
        {
            if (path[i] == '/')
            {
                if (segmentLength == 0)
                {
                    continue;
                }

                var name = new string(segment[..segmentLength]);
                var index = FindPathBlockIndex(blockIndex, name);
                if (index < 1)
                {
                    throw Error($"Path '{path}' does not exist.");
                }

                blockIndex = index;
                segmentLength = 0;
                continue;
            }

            if (segmentLength >= FileSystemInternal.BlockNameMaxSize)
            {
                throw Error($"Path segment in '{path}' exceeds {FileSystemInternal.BlockNameMaxSize} bytes.");
            }

            segment[segmentLength++] = path[i];
        }

        if (segmentLength == 0)
        {
            throw Error($"Invalid file path '{path}'.");
        }

        var lastName = new string(segment[..segmentLength]);
        if (lastName is "." or "..")
        {
            throw Error($"Invalid file name '{path}'.");
        }

        FileHandle? handle = byteMode switch
        {
            0 or 3 => DoFopenRead(lastName, byteMode, blockIndex),
            1 or 4 => DoFopenWrite(lastName, byteMode, blockIndex),
            2 or 5 => DoFopenAppend(lastName, byteMode, blockIndex),
            _ => null,
        };

        return handle ?? throw Error($"Unable to open '{path}' in mode '{mode}'.");
    }

    private FileHandle? DoFopenRead(string lastName, byte mode, uint blockHeadIndex)
    {
        var block = new byte[FileSystemInternal.BlockSize];
        if (!ReadBlock(blockHeadIndex, block))
        {
            return null;
        }

        var stopBlockIndex = FileSystemUtil.ReadUInt32(block.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4));
        var offset = FileSystemUtil.ReadUInt16(block.AsSpan(FileSystemInternal.BlockOffset, 2));

        var found = false;
        uint dirBlockIndex = 0;
        ushort dirOffset = 0;
        var index = blockHeadIndex;

        while (true)
        {
            var k = FileSystemInternal.BlockHead;
            for (var i = 0; i < FileSystemInternal.BlockItemMaxCount; i++)
            {
                var state = block[k++];
                var entryName = FileSystemUtil.FixedNameToString(block.AsSpan(k, FileSystemInternal.BlockNameMaxSize));
                k += FileSystemInternal.BlockNameMaxSize;
                if (!string.Equals(entryName, lastName, StringComparison.Ordinal))
                {
                    k += 10;
                    if (index == stopBlockIndex && k + 1 >= offset)
                    {
                        return null;
                    }

                    continue;
                }

                if ((state & 0x01) == 0)
                {
                    return null;
                }

                dirBlockIndex = index;
                dirOffset = (ushort)(k + 10);
                found = true;
                break;
            }

            if (found)
            {
                break;
            }

            index = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
            if (index == 0 || !ReadBlock(index, block))
            {
                return null;
            }
        }

        return new FileHandle(this)
        {
            Mode = mode,
            DirBlockIndex = dirBlockIndex,
            DirOffset = dirOffset,
            FileStartBlockIndex = FileSystemUtil.ReadUInt32(block.AsSpan(dirOffset - 10, 4)),
            FileStopBlockIndex = FileSystemUtil.ReadUInt32(block.AsSpan(dirOffset - 6, 4)),
            FileOffset = FileSystemUtil.ReadUInt16(block.AsSpan(dirOffset - 2, 2)),
            PosBlockIndex = FileSystemUtil.ReadUInt32(block.AsSpan(dirOffset - 10, 4)),
            PosOffset = FileSystemInternal.BlockHead,
            Pos = 0,
        };
    }

    private bool DoFopenCreateFileItem(
        string lastName,
        uint originalStartBlockIndex,
        uint originalStopBlockIndex,
        ushort originalOffset,
        byte[] dirBlock,
        out uint dirBlockIndex,
        out ushort dirOffset)
    {
        Span<byte> b4 = stackalloc byte[4];
        Span<byte> b2 = stackalloc byte[2];

        var caches = new[] { new BlockCache(), new BlockCache() };
        if (!ReadBlock(originalStartBlockIndex, caches[0].Block))
        {
            dirBlockIndex = 0;
            dirOffset = 0;
            return false;
        }

        caches[0].BlockIndex = originalStartBlockIndex;
        caches[0].Active = true;
        var blockStart = caches[0].Block;
        var blockStartIndex = caches[0].BlockIndex;

        byte[] blockStop;
        uint blockStopIndex;
        if (originalStopBlockIndex == originalStartBlockIndex)
        {
            blockStop = blockStart;
            blockStopIndex = blockStartIndex;
        }
        else
        {
            if (!ReadBlock(originalStopBlockIndex, caches[1].Block))
            {
                dirBlockIndex = 0;
                dirOffset = 0;
                return false;
            }

            caches[1].BlockIndex = originalStopBlockIndex;
            caches[1].Active = true;
            blockStop = caches[1].Block;
            blockStopIndex = caches[1].BlockIndex;
        }

        var autoCommit = _tmp.State == 0;
        if (autoCommit && !StartTransaction(1))
        {
            dirBlockIndex = 0;
            dirOffset = 0;
            return false;
        }

        if (originalOffset < FileSystemInternal.BlockSize)
        {
            var k = originalOffset;
            blockStop[k++] = 1;
            FileSystemUtil.CopyName(blockStop.AsSpan(k, FileSystemInternal.BlockNameMaxSize), lastName);
            k += FileSystemInternal.BlockNameMaxSize;
            k += 4;
            k += 4;
            k += 2;

            var newOffset = (ushort)k;
            FileSystemUtil.WriteUInt16(b2, newOffset);
            b2.CopyTo(blockStart.AsSpan(FileSystemInternal.BlockOffset, 2));

            foreach (var cache in caches)
            {
                if (!cache.Active || WriteBlock(cache.BlockIndex, cache.Block))
                {
                    continue;
                }

                if (autoCommit)
                {
                    StopTransaction();
                }

                dirBlockIndex = 0;
                dirOffset = 0;
                return false;
            }

            if (autoCommit)
            {
                Commit();
            }

            blockStop.CopyTo(dirBlock, 0);
            dirBlockIndex = blockStopIndex;
            dirOffset = newOffset;
            return true;
        }

        var newBlockIndex = GenerateBlockIndex();
        if (newBlockIndex == 0)
        {
            if (autoCommit)
            {
                StopTransaction();
            }

            dirBlockIndex = 0;
            dirOffset = 0;
            return false;
        }

        var newBlock = new byte[FileSystemInternal.BlockSize];
        FileSystemUtil.WriteUInt32(newBlock.AsSpan(8, 4), originalStopBlockIndex);
        var cursor = 12;
        newBlock[cursor++] = 1;
        FileSystemUtil.CopyName(newBlock.AsSpan(cursor, FileSystemInternal.BlockNameMaxSize), lastName);
        cursor += FileSystemInternal.BlockNameMaxSize;
        cursor += 4;
        cursor += 4;
        cursor += 2;

        var appendedOffset = (ushort)cursor;
        FileSystemUtil.WriteUInt16(blockStart.AsSpan(FileSystemInternal.BlockOffset, 2), appendedOffset);
        FileSystemUtil.WriteUInt32(blockStart.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4), newBlockIndex);
        FileSystemUtil.WriteUInt32(blockStop.AsSpan(4, 4), newBlockIndex);

        if (!WriteBlock(newBlockIndex, newBlock))
        {
            if (autoCommit)
            {
                StopTransaction();
            }

            dirBlockIndex = 0;
            dirOffset = 0;
            return false;
        }

        foreach (var cache in caches)
        {
            if (!cache.Active || WriteBlock(cache.BlockIndex, cache.Block))
            {
                continue;
            }

            if (autoCommit)
            {
                StopTransaction();
            }

            dirBlockIndex = 0;
            dirOffset = 0;
            return false;
        }

        if (autoCommit)
        {
            Commit();
        }

        newBlock.CopyTo(dirBlock, 0);
        dirBlockIndex = newBlockIndex;
        dirOffset = appendedOffset;
        return true;
    }

    private bool DoFopenCleanFileContent(byte[] dirBlock, uint dirBlockIndex, ushort dirOffset)
    {
        var fileStart = FileSystemUtil.ReadUInt32(dirBlock.AsSpan(dirOffset - 10, 4));
        var fileStop = FileSystemUtil.ReadUInt32(dirBlock.AsSpan(dirOffset - 6, 4));
        if (fileStart == 0)
        {
            return true;
        }

        var autoCommit = _tmp.State == 0;
        if (autoCommit && !StartTransaction(1))
        {
            return false;
        }

        var fileStopBlock = new byte[FileSystemInternal.BlockSize];
        if (!ReadBlock(fileStop, fileStopBlock))
        {
            if (autoCommit)
            {
                StopTransaction();
            }

            return false;
        }

        FileSystemUtil.WriteUInt32(fileStopBlock.AsSpan(4, 4), _tmp.NewUnusedBlockHead);
        _tmp.NewUnusedBlockHead = fileStart;
        dirBlock.AsSpan(dirOffset - 10, 10).Clear();

        if (!WriteBlock(dirBlockIndex, dirBlock) || !WriteBlock(fileStop, fileStopBlock))
        {
            if (autoCommit)
            {
                StopTransaction();
            }

            return false;
        }

        if (autoCommit)
        {
            Commit();
        }

        return true;
    }

    private FileHandle? DoFopenWrite(string lastName, byte mode, uint blockHeadIndex)
    {
        var block = new byte[FileSystemInternal.BlockSize];
        if (!ReadBlock(blockHeadIndex, block))
        {
            return null;
        }

        var stopBlockIndex = FileSystemUtil.ReadUInt32(block.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4));
        var offset = FileSystemUtil.ReadUInt16(block.AsSpan(FileSystemInternal.BlockOffset, 2));

        var found = false;
        var dirExists = false;
        uint dirBlockIndex = 0;
        ushort dirOffset = 0;
        var index = blockHeadIndex;

        while (true)
        {
            var k = FileSystemInternal.BlockHead;
            for (var i = 0; i < FileSystemInternal.BlockItemMaxCount; i++)
            {
                var state = block[k++];
                var entryName = FileSystemUtil.FixedNameToString(block.AsSpan(k, FileSystemInternal.BlockNameMaxSize));
                k += FileSystemInternal.BlockNameMaxSize;
                if (!string.Equals(entryName, lastName, StringComparison.Ordinal))
                {
                    k += 10;
                    if (index == stopBlockIndex && k + 1 >= offset)
                    {
                        found = true;
                        break;
                    }

                    continue;
                }

                if ((state & 0x01) == 0)
                {
                    return null;
                }

                dirBlockIndex = index;
                dirOffset = (ushort)(k + 10);
                dirExists = true;
                found = true;
                break;
            }

            if (found)
            {
                break;
            }

            index = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
            if (index == 0 || !ReadBlock(index, block))
            {
                return null;
            }
        }

        if (!dirExists)
        {
            if (!DoFopenCreateFileItem(lastName, blockHeadIndex, stopBlockIndex, offset, block, out dirBlockIndex, out dirOffset))
            {
                return null;
            }
        }
        else if (!DoFopenCleanFileContent(block, dirBlockIndex, dirOffset))
        {
            return null;
        }

        return new FileHandle(this)
        {
            Mode = mode,
            DirBlockIndex = dirBlockIndex,
            DirOffset = dirOffset,
            FileStartBlockIndex = 0,
            FileStopBlockIndex = 0,
            FileOffset = 0,
            PosBlockIndex = 0,
            PosOffset = 0,
            Pos = 0,
        };
    }

    private FileHandle? DoFopenAppend(string lastName, byte mode, uint blockHeadIndex)
    {
        var block = new byte[FileSystemInternal.BlockSize];
        if (!ReadBlock(blockHeadIndex, block))
        {
            return null;
        }

        var stopBlockIndex = FileSystemUtil.ReadUInt32(block.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4));
        var offset = FileSystemUtil.ReadUInt16(block.AsSpan(FileSystemInternal.BlockOffset, 2));

        var found = false;
        var dirExists = false;
        uint dirBlockIndex = 0;
        ushort dirOffset = 0;
        var index = blockHeadIndex;

        while (true)
        {
            var k = FileSystemInternal.BlockHead;
            for (var i = 0; i < FileSystemInternal.BlockItemMaxCount; i++)
            {
                var state = block[k++];
                var entryName = FileSystemUtil.FixedNameToString(block.AsSpan(k, FileSystemInternal.BlockNameMaxSize));
                k += FileSystemInternal.BlockNameMaxSize;
                if (!string.Equals(entryName, lastName, StringComparison.Ordinal))
                {
                    k += 10;
                    if (index == stopBlockIndex && k + 1 >= offset)
                    {
                        found = true;
                        break;
                    }

                    continue;
                }

                if ((state & 0x01) == 0)
                {
                    return null;
                }

                dirBlockIndex = index;
                dirOffset = (ushort)(k + 10);
                dirExists = true;
                found = true;
                break;
            }

            if (found)
            {
                break;
            }

            index = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
            if (index == 0 || !ReadBlock(index, block))
            {
                return null;
            }
        }

        if (!dirExists)
        {
            if (!DoFopenCreateFileItem(lastName, blockHeadIndex, stopBlockIndex, offset, block, out dirBlockIndex, out dirOffset))
            {
                return null;
            }

            return new FileHandle(this)
            {
                Mode = mode,
                DirBlockIndex = dirBlockIndex,
                DirOffset = dirOffset,
                FileStartBlockIndex = 0,
                FileStopBlockIndex = 0,
                FileOffset = 0,
                PosBlockIndex = 0,
                PosOffset = 0,
                Pos = 0,
            };
        }

        var fileStart = FileSystemUtil.ReadUInt32(block.AsSpan(dirOffset - 10, 4));
        var fileStop = FileSystemUtil.ReadUInt32(block.AsSpan(dirOffset - 6, 4));
        var fileOffset = FileSystemUtil.ReadUInt16(block.AsSpan(dirOffset - 2, 2));

        ulong pos = 0;
        index = fileStart;
        while (index != 0)
        {
            if (index == fileStop)
            {
                pos += (ulong)(fileOffset - FileSystemInternal.BlockHead);
                break;
            }

            if (!ReadBlock(index, block))
            {
                return null;
            }

            pos += (ulong)(FileSystemInternal.BlockSize - FileSystemInternal.BlockHead);
            index = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
        }

        return new FileHandle(this)
        {
            Mode = mode,
            DirBlockIndex = dirBlockIndex,
            DirOffset = dirOffset,
            FileStartBlockIndex = fileStart,
            FileStopBlockIndex = fileStop,
            FileOffset = fileOffset,
            PosBlockIndex = fileStop,
            PosOffset = fileOffset,
            Pos = pos,
        };
    }
}
