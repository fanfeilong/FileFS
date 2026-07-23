namespace FileFS;

public sealed partial class FileSystem
{
    public void Mkdir(string path)
    {
        EnsureMounted();
        var result = MkdirInternal(path);
        if (result != 0)
        {
            throw Error($"Unable to create directory '{path}' (code {result}).");
        }
    }

    public void Rmdir(string path)
    {
        EnsureMounted();
        var result = RmdirInternal(path);
        if (result != 0)
        {
            throw Error($"Unable to remove directory '{path}' (code {result}).");
        }
    }

    public DirectoryHandle OpenDir(string path)
    {
        EnsureMounted();

        if (!TryOpenDir(path, out var handle))
        {
            throw Error($"Unable to open directory '{path}'.");
        }

        return handle!;
    }

    public DirEntry? ReadDir(DirectoryHandle dir)
    {
        EnsureMounted();
        ArgumentNullException.ThrowIfNull(dir);

        if (dir.IsClosed)
        {
            throw Error("Directory handle is closed.");
        }

        var block = dir.Block;
        var k = FileSystemInternal.BlockHead + dir.SearchIndex * 25;
        if (dir.BlockIndex == dir.StopBlockIndex && k + 1 >= dir.Offset)
        {
            return null;
        }

        while (true)
        {
            if (dir.SearchIndex >= FileSystemInternal.BlockItemMaxCount)
            {
                var nextIndex = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
                if (nextIndex == 0 || !ReadBlock(nextIndex, dir.Block))
                {
                    return null;
                }

                block = dir.Block;
                dir.SearchIndex = 0;
                dir.BlockIndex = nextIndex;
                k = FileSystemInternal.BlockHead;
                continue;
            }

            var state = block[k++];
            dir.CachedEntry.Type = (state & 0x01) == 0x01 ? FileType.File : FileType.Directory;
            dir.CachedEntry.Name = FileSystemUtil.FixedNameToString(block.AsSpan(k, FileSystemInternal.BlockNameMaxSize));
            k += FileSystemInternal.BlockNameMaxSize;

            if (dir.CachedEntry.Name == ".")
            {
                var dirBlockIndex = FileSystemUtil.ReadUInt32(block.AsSpan(k, 4));
                if (dirBlockIndex == 1)
                {
                    dir.CachedEntry.Type = FileType.Root;
                }
            }
            else if (dir.CachedEntry.Name == "..")
            {
                var dirBlockIndex = FileSystemUtil.ReadUInt32(block.AsSpan(k, 4));
                if (dirBlockIndex == 0)
                {
                    dir.CachedEntry.Type = FileType.Root;
                }
            }

            k += 10;
            dir.SearchIndex++;
            return dir.CachedEntry;
        }
    }

    public void CloseDir(DirectoryHandle dir)
    {
        ArgumentNullException.ThrowIfNull(dir);
    }

    private int DoMkdir(
        string lastName,
        uint startBlockIndex,
        byte[] startBlock,
        uint currentBlockIndex,
        byte[] currentBlock,
        ushort offset)
    {
        var autoCommit = _tmp.State == 0;
        if (autoCommit && !StartTransaction(1))
        {
            return 1;
        }

        Span<byte> b4 = stackalloc byte[4];
        Span<byte> b2 = stackalloc byte[2];

        if (offset < FileSystemInternal.BlockSize)
        {
            var newBlockIndex = GenerateBlockIndex();
            if (newBlockIndex == 0)
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }

            var newBlock = new byte[FileSystemInternal.BlockSize];
            var k = FileSystemInternal.BlockHead;
            newBlock[k++] = 0;
            FileSystemUtil.CopyName(newBlock.AsSpan(k, FileSystemInternal.BlockNameMaxSize), ".");
            k += FileSystemInternal.BlockNameMaxSize;
            FileSystemUtil.WriteUInt32(newBlock.AsSpan(k, 4), newBlockIndex);
            k += 4;
            FileSystemUtil.WriteUInt32(newBlock.AsSpan(k, 4), newBlockIndex);
            k += 4;
            FileSystemUtil.WriteUInt16(newBlock.AsSpan(k, 2), 62);
            k += 2;

            newBlock[k++] = 0;
            FileSystemUtil.CopyName(newBlock.AsSpan(k, FileSystemInternal.BlockNameMaxSize), "..");
            k += FileSystemInternal.BlockNameMaxSize;
            FileSystemUtil.WriteUInt32(newBlock.AsSpan(k, 4), startBlockIndex);

            if (!WriteBlock(newBlockIndex, newBlock))
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }

            k = offset;
            currentBlock[k++] = 0;
            FileSystemUtil.CopyName(currentBlock.AsSpan(k, FileSystemInternal.BlockNameMaxSize), lastName);
            k += FileSystemInternal.BlockNameMaxSize;
            FileSystemUtil.WriteUInt32(currentBlock.AsSpan(k, 4), newBlockIndex);
            k += 4;
            k += 4;
            k += 2;

            var itemEndOffset = (ushort)k;
            FileSystemUtil.WriteUInt16(b2, itemEndOffset);

            if (currentBlockIndex == startBlockIndex)
            {
                b2.CopyTo(currentBlock.AsSpan(FileSystemInternal.BlockOffset, 2));
                if (!WriteBlock(currentBlockIndex, currentBlock))
                {
                    if (autoCommit)
                    {
                        StopTransaction();
                    }

                    return 1;
                }
            }
            else
            {
                if (!WriteBlock(currentBlockIndex, currentBlock))
                {
                    if (autoCommit)
                    {
                        StopTransaction();
                    }

                    return 1;
                }

                b2.CopyTo(startBlock.AsSpan(FileSystemInternal.BlockOffset, 2));
                if (!WriteBlock(startBlockIndex, startBlock))
                {
                    if (autoCommit)
                    {
                        StopTransaction();
                    }

                    return 1;
                }
            }

            if (autoCommit)
            {
                Commit();
            }

            return 0;
        }

        var childBlockIndex = GenerateBlockIndex();
        var parentTailBlockIndex = GenerateBlockIndex();
        if (childBlockIndex == 0 || parentTailBlockIndex == 0)
        {
            if (autoCommit)
            {
                StopTransaction();
            }

            return 1;
        }

        var parentTail = new byte[FileSystemInternal.BlockSize];
        FileSystemUtil.WriteUInt32(parentTail.AsSpan(8, 4), currentBlockIndex);
        var cursor = 12;
        parentTail[cursor++] = 0;
        FileSystemUtil.CopyName(parentTail.AsSpan(cursor, FileSystemInternal.BlockNameMaxSize), lastName);
        cursor += FileSystemInternal.BlockNameMaxSize;
        FileSystemUtil.WriteUInt32(parentTail.AsSpan(cursor, 4), childBlockIndex);
        cursor += 4;
        cursor += 4;
        cursor += 2;

        var newOffset = (ushort)cursor;
        if (!WriteBlock(parentTailBlockIndex, parentTail))
        {
            if (autoCommit)
            {
                StopTransaction();
            }

            return 1;
        }

        var childBlock = new byte[FileSystemInternal.BlockSize];
        cursor = FileSystemInternal.BlockHead;
        childBlock[cursor++] = 0;
        FileSystemUtil.CopyName(childBlock.AsSpan(cursor, FileSystemInternal.BlockNameMaxSize), ".");
        cursor += FileSystemInternal.BlockNameMaxSize;
        FileSystemUtil.WriteUInt32(childBlock.AsSpan(cursor, 4), childBlockIndex);
        cursor += 4;
        FileSystemUtil.WriteUInt32(childBlock.AsSpan(cursor, 4), childBlockIndex);
        cursor += 4;
        FileSystemUtil.WriteUInt16(childBlock.AsSpan(cursor, 2), 62);
        cursor += 2;
        childBlock[cursor++] = 0;
        FileSystemUtil.CopyName(childBlock.AsSpan(cursor, FileSystemInternal.BlockNameMaxSize), "..");
        cursor += FileSystemInternal.BlockNameMaxSize;
        FileSystemUtil.WriteUInt32(childBlock.AsSpan(cursor, 4), startBlockIndex);

        if (!WriteBlock(childBlockIndex, childBlock))
        {
            if (autoCommit)
            {
                StopTransaction();
            }

            return 1;
        }

        FileSystemUtil.WriteUInt16(b2, newOffset);
        FileSystemUtil.WriteUInt32(b4, parentTailBlockIndex);
        b4.CopyTo(currentBlock.AsSpan(4, 4));

        if (currentBlockIndex == startBlockIndex)
        {
            b4.CopyTo(currentBlock.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4));
            b2.CopyTo(currentBlock.AsSpan(FileSystemInternal.BlockOffset, 2));
            if (!WriteBlock(currentBlockIndex, currentBlock))
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }
        }
        else
        {
            if (!WriteBlock(currentBlockIndex, currentBlock))
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }

            b4.CopyTo(startBlock.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4));
            b2.CopyTo(startBlock.AsSpan(FileSystemInternal.BlockOffset, 2));
            if (!WriteBlock(startBlockIndex, startBlock))
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }
        }

        if (autoCommit)
        {
            Commit();
        }

        return 0;
    }

    private int MkdirInternal(string path)
    {
        if (string.IsNullOrEmpty(path))
        {
            return 1;
        }

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

                var index = FindPathBlockIndex(blockIndex, new string(segment[..segmentLength]));
                if (index < 1)
                {
                    if (i == path.Length - 1)
                    {
                        break;
                    }

                    return 1;
                }

                blockIndex = index;
                segmentLength = 0;
                continue;
            }

            if (segmentLength >= FileSystemInternal.BlockNameMaxSize)
            {
                return 2;
            }

            segment[segmentLength++] = path[i];
        }

        if (segmentLength == 0)
        {
            return 3;
        }

        var lastName = new string(segment[..segmentLength]);
        var startBlock = new byte[FileSystemInternal.BlockSize];
        var block = new byte[FileSystemInternal.BlockSize];
        if (!ReadBlock(blockIndex, block))
        {
            return 1;
        }

        Array.Copy(block, startBlock, block.Length);
        var startBlockIndex = blockIndex;
        var stopBlockIndex = FileSystemUtil.ReadUInt32(block.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4));
        var offset = FileSystemUtil.ReadUInt16(block.AsSpan(FileSystemInternal.BlockOffset, 2));

        var indexBlock = startBlockIndex;
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
                    if (indexBlock == stopBlockIndex && k + 1 >= offset)
                    {
                        return DoMkdir(lastName, startBlockIndex, startBlock, indexBlock, block, offset);
                    }

                    continue;
                }

                return (state & 0x01) == 0 ? 3 : 4;
            }

            indexBlock = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
            if (indexBlock == 0 || !ReadBlock(indexBlock, block))
            {
                return 1;
            }
        }
    }

    private int RmdirInternal(string path)
    {
        if (string.IsNullOrEmpty(path))
        {
            return 1;
        }

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

                if (i == path.Length - 1)
                {
                    break;
                }

                var index = FindPathBlockIndex(blockIndex, new string(segment[..segmentLength]));
                if (index < 1)
                {
                    return 3;
                }

                blockIndex = index;
                segmentLength = 0;
                continue;
            }

            if (segmentLength >= FileSystemInternal.BlockNameMaxSize)
            {
                return 4;
            }

            segment[segmentLength++] = path[i];
        }

        var lastName = new string(segment[..segmentLength]);
        if (lastName is "." or "..")
        {
            return 1;
        }

        var caches = new[] { new BlockCache(), new BlockCache(), new BlockCache(), new BlockCache() };
        var block = new byte[FileSystemInternal.BlockSize];
        if (!ReadBlock(blockIndex, block))
        {
            return 1;
        }

        Array.Copy(block, caches[0].Block, block.Length);
        caches[0].BlockIndex = blockIndex;
        caches[0].Active = true;
        var blockHead = caches[0].Block;
        var blockHeadIndex = blockIndex;
        var used = 1;

        var stopBlockIndex = FileSystemUtil.ReadUInt32(blockHead.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4));
        var offset = FileSystemUtil.ReadUInt16(blockHead.AsSpan(FileSystemInternal.BlockOffset, 2));

        byte[] blockLast;
        uint blockLastIndex;
        if (stopBlockIndex == blockHeadIndex)
        {
            blockLast = blockHead;
            blockLastIndex = blockHeadIndex;
        }
        else
        {
            if (!ReadBlock(stopBlockIndex, caches[1].Block))
            {
                return 1;
            }

            caches[1].BlockIndex = stopBlockIndex;
            caches[1].Active = true;
            blockLast = caches[1].Block;
            blockLastIndex = stopBlockIndex;
            used++;
        }

        byte[]? blockItem = null;
        uint blockItemIndex = 0;
        ushort itemOffset = 0;
        uint subdirBlockIndex = 0;
        var subdirBlock = new byte[FileSystemInternal.BlockSize];

        var indexBlock = blockHeadIndex;
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
                    if (indexBlock == stopBlockIndex && k + 1 >= offset)
                    {
                        return 3;
                    }

                    continue;
                }

                if ((state & 0x01) == 0x01)
                {
                    return 3;
                }

                subdirBlockIndex = FileSystemUtil.ReadUInt32(block.AsSpan(k, 4));
                if (!ReadBlock(subdirBlockIndex, subdirBlock))
                {
                    return 1;
                }

                var subdirStart = FileSystemUtil.ReadUInt32(subdirBlock.AsSpan(FileSystemInternal.BlockStartBlockIndex, 4));
                var subdirStop = FileSystemUtil.ReadUInt32(subdirBlock.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4));
                var subdirOffset = FileSystemUtil.ReadUInt16(subdirBlock.AsSpan(FileSystemInternal.BlockOffset, 2));
                if (subdirStop != subdirStart || subdirOffset > 62)
                {
                    return 2;
                }

                itemOffset = (ushort)(k + 10);
                for (var j = 0; j < used; j++)
                {
                    if (caches[j].BlockIndex != indexBlock)
                    {
                        continue;
                    }

                    blockItem = caches[j].Block;
                    blockItemIndex = indexBlock;
                    break;
                }

                if (blockItem is null)
                {
                    Array.Copy(block, caches[used].Block, block.Length);
                    caches[used].BlockIndex = indexBlock;
                    caches[used].Active = true;
                    blockItem = caches[used].Block;
                    blockItemIndex = indexBlock;
                    used++;
                }

                goto FoundDirectory;
            }

            indexBlock = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
            if (indexBlock == 0 || !ReadBlock(indexBlock, block))
            {
                return 1;
            }
        }

    FoundDirectory:
        var autoCommit = _tmp.State == 0;
        if (autoCommit && !StartTransaction(1))
        {
            return 1;
        }

        RemoveBlock(subdirBlockIndex);

        if (blockItemIndex != stopBlockIndex || itemOffset != offset)
        {
            Array.Copy(blockLast, offset - 25, blockItem!, itemOffset - 25, 25);
        }

        offset -= 25;
        FileSystemUtil.WriteUInt16(blockHead.AsSpan(FileSystemInternal.BlockOffset, 2), offset);

        if (offset < 25)
        {
            var blockPrevIndex = FileSystemUtil.ReadUInt32(blockLast.AsSpan(8, 4));
            RemoveBlock(blockLastIndex);
            var freedSlot = -1;
            for (var i = 0; i < used; i++)
            {
                if (caches[i].BlockIndex != blockLastIndex)
                {
                    continue;
                }

                caches[i].Active = false;
                freedSlot = i;
                break;
            }

            if (freedSlot < 0)
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }

            byte[]? blockPrev = null;
            for (var i = 0; i < used; i++)
            {
                if (caches[i].BlockIndex != blockPrevIndex)
                {
                    continue;
                }

                blockPrev = caches[i].Block;
                break;
            }

            if (blockPrev is null)
            {
                if (!ReadBlock(blockPrevIndex, block))
                {
                    if (autoCommit)
                    {
                        StopTransaction();
                    }

                    return 1;
                }

                Array.Copy(block, caches[freedSlot].Block, block.Length);
                caches[freedSlot].BlockIndex = blockPrevIndex;
                caches[freedSlot].Active = true;
                blockPrev = caches[freedSlot].Block;
            }

            blockPrev.AsSpan(4, 4).Clear();
            FileSystemUtil.WriteUInt32(blockHead.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4), blockPrevIndex);
            FileSystemUtil.WriteUInt16(blockHead.AsSpan(FileSystemInternal.BlockOffset, 2), FileSystemInternal.BlockSize);
        }

        for (var i = 0; i < used; i++)
        {
            if (caches[i].Active && !WriteBlock(caches[i].BlockIndex, caches[i].Block))
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }
        }

        if (autoCommit)
        {
            Commit();
        }

        return 0;
    }

    private bool TryOpenDir(string path, out DirectoryHandle? handle)
    {
        handle = null;

        uint blockIndex;
        var start = 0;
        if (!string.IsNullOrEmpty(path) && path[0] == '/')
        {
            blockIndex = 1;
            start = 1;
            InitPwdTmp("/");
        }
        else
        {
            blockIndex = CurrentPwdBlockIndex;
            InitPwdTmp(CurrentPwd);
        }

        path ??= string.Empty;
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

                var component = new string(segment[..segmentLength]);
                var index = FindPathBlockIndex(blockIndex, component);
                if (index < 1 || !AddToPwdTmp(component))
                {
                    return false;
                }

                blockIndex = index;
                segmentLength = 0;
                continue;
            }

            if (segmentLength >= FileSystemInternal.BlockNameMaxSize)
            {
                return false;
            }

            segment[segmentLength++] = path[i];
        }

        if (segmentLength > 0)
        {
            var component = new string(segment[..segmentLength]);
            var index = FindPathBlockIndex(blockIndex, component);
            if (index < 1 || !AddToPwdTmp(component))
            {
                return false;
            }

            blockIndex = index;
        }

        var dir = new DirectoryHandle(this)
        {
            BlockIndex = blockIndex,
            SearchIndex = 0,
        };

        if (!ReadBlock(blockIndex, dir.Block))
        {
            return false;
        }

        dir.StopBlockIndex = FileSystemUtil.ReadUInt32(dir.Block.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4));
        dir.Offset = FileSystemUtil.ReadUInt16(dir.Block.AsSpan(FileSystemInternal.BlockOffset, 2));
        handle = dir;
        return true;
    }
}
