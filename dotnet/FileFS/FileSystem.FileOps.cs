namespace FileFS;

public sealed partial class FileSystem
{
    public void RemoveFile(string path)
    {
        EnsureMounted();
        var result = RemoveInternal(path);
        if (result != 0)
        {
            throw Error($"Unable to remove file '{path}' (code {result}).");
        }
    }

    public void Rename(string from, string to)
    {
        EnsureMounted();
        var result = RenameInternal(from, to);
        if (result != 0)
        {
            throw Error($"Unable to rename '{from}' to '{to}' (code {result}).");
        }
    }

    public void Move(string from, string toDir)
    {
        EnsureMounted();
        var result = MoveInternal(from, toDir);
        if (result != 0)
        {
            throw Error($"Unable to move '{from}' into '{toDir}' (code {result}).");
        }
    }

    public void CopyFile(string from, string to)
    {
        EnsureMounted();
        ArgumentException.ThrowIfNullOrEmpty(from);
        ArgumentException.ThrowIfNullOrEmpty(to);

        if (Stat(from) != 1)
        {
            throw Error($"Source file '{from}' does not exist.");
        }

        if (Stat(to) != 0)
        {
            throw Error($"Destination '{to}' already exists.");
        }

        using var source = Open(from, "r");
        using var destination = Open(to, "w");
        var buffer = new byte[4096];
        while (true)
        {
            var read = Read(source, buffer);
            if (read == 0)
            {
                break;
            }

            _ = Write(destination, buffer.AsSpan(0, read));
        }
    }

    private int RemoveInternal(string path)
    {
        if (string.IsNullOrEmpty(path))
        {
            return 1;
        }

        if (path[^1] == '/')
        {
            return 5;
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

        if (segmentLength == 0)
        {
            return 2;
        }

        var lastName = new string(segment[..segmentLength]);
        if (lastName is "." or "..")
        {
            return 5;
        }

        var caches = new[] { new BlockCache(), new BlockCache(), new BlockCache(), new BlockCache() };
        var used = 0;
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
        used = 1;

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
        uint fileStart = 0;
        uint fileStop = 0;

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
                        return 2;
                    }

                    continue;
                }

                if ((state & 0x01) == 0)
                {
                    return 2;
                }

                fileStart = FileSystemUtil.ReadUInt32(block.AsSpan(k, 4));
                fileStop = FileSystemUtil.ReadUInt32(block.AsSpan(k + 4, 4));
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

                goto FoundFile;
            }

            indexBlock = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
            if (indexBlock == 0 || !ReadBlock(indexBlock, block))
            {
                return 1;
            }
        }

    FoundFile:
        var autoCommit = _tmp.State == 0;
        if (autoCommit && !StartTransaction(1))
        {
            return 1;
        }

        if (fileStart > 0)
        {
            var fileBlockStop = new byte[FileSystemInternal.BlockSize];
            if (!ReadBlock(fileStop, fileBlockStop))
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }

            FileSystemUtil.WriteUInt32(fileBlockStop.AsSpan(4, 4), _tmp.NewUnusedBlockHead);
            _tmp.NewUnusedBlockHead = fileStart;
            if (!WriteBlock(fileStop, fileBlockStop))
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }
        }

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

    private int RenameInternal(string oldName, string newName)
    {
        if (string.IsNullOrEmpty(oldName) || string.IsNullOrEmpty(newName))
        {
            return 1;
        }

        var oldResult = ResolveRenameTarget(oldName, 2, out var oldBlockIndex, out var oldLastName, out var oldTypeDir);
        if (oldResult != 0)
        {
            return oldResult;
        }

        var newResult = ResolveRenameTarget(newName, 3, out var newBlockIndex, out var newLastName, out var newTypeDir);
        if (newResult != 0)
        {
            return newResult;
        }

        return DoRename(oldLastName, oldBlockIndex, oldTypeDir, newLastName, newBlockIndex, newTypeDir);
    }

    private int MoveInternal(string fromName, string toPath)
    {
        if (string.IsNullOrEmpty(fromName) || string.IsNullOrEmpty(toPath))
        {
            return 1;
        }

        var fromResult = ResolveRenameTarget(fromName, 2, out var fromBlockIndex, out var fromLastName, out var fromTypeDir);
        if (fromResult != 0)
        {
            return fromResult;
        }

        uint blockIndex;
        var start = 0;
        if (toPath[0] == '/')
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
        for (var i = start; i < toPath.Length; i++)
        {
            if (toPath[i] == '/')
            {
                if (segmentLength == 0)
                {
                    continue;
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
                return 3;
            }

            segment[segmentLength++] = toPath[i];
        }

        if (segmentLength > 0)
        {
            var index = FindPathBlockIndex(blockIndex, new string(segment[..segmentLength]));
            if (index < 1)
            {
                return 3;
            }

            blockIndex = index;
        }

        return DoRename(fromLastName, fromBlockIndex, fromTypeDir, fromLastName, blockIndex, fromTypeDir);
    }

    private int ResolveRenameTarget(string path, int invalidCode, out uint blockIndex, out string lastName, out byte typeDir)
    {
        blockIndex = 0;
        lastName = string.Empty;
        typeDir = 0;

        if (string.IsNullOrEmpty(path))
        {
            return 1;
        }

        uint currentBlockIndex;
        var start = 0;
        if (path[0] == '/')
        {
            currentBlockIndex = 1;
            start = 1;
        }
        else
        {
            currentBlockIndex = CurrentPwdBlockIndex;
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

                var index = FindPathBlockIndex(currentBlockIndex, new string(segment[..segmentLength]));
                if (index < 1)
                {
                    return invalidCode;
                }

                currentBlockIndex = index;
                segmentLength = 0;
                continue;
            }

            if (segmentLength >= FileSystemInternal.BlockNameMaxSize)
            {
                return invalidCode;
            }

            segment[segmentLength++] = path[i];
        }

        if (segmentLength > FileSystemInternal.BlockNameMaxSize)
        {
            return invalidCode;
        }

        lastName = new string(segment[..segmentLength]);
        if (lastName is "." or "..")
        {
            return invalidCode;
        }

        blockIndex = currentBlockIndex;
        if (path[^1] == '/')
        {
            typeDir = 1;
        }

        return 0;
    }

    private int DoRename(string oldLastName, uint oldBlockIndex, byte oldTypeDir, string newLastName, uint newBlockIndex, byte newTypeDir)
    {
        Span<byte> b4 = stackalloc byte[4];
        Span<byte> b2 = stackalloc byte[2];

        var oldCaches = new[] { new BlockCache(), new BlockCache(), new BlockCache(), new BlockCache() };
        var oldUsed = 1;
        var oldBlock = new byte[FileSystemInternal.BlockSize];
        if (!ReadBlock(oldBlockIndex, oldBlock))
        {
            return 1;
        }

        Array.Copy(oldBlock, oldCaches[0].Block, oldBlock.Length);
        oldCaches[0].BlockIndex = oldBlockIndex;
        oldCaches[0].Active = true;
        var oldBlockHead = oldCaches[0].Block;
        var oldBlockHeadIndex = oldBlockIndex;
        var oldStopBlockIndex = FileSystemUtil.ReadUInt32(oldBlockHead.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4));
        var oldOffset = FileSystemUtil.ReadUInt16(oldBlockHead.AsSpan(FileSystemInternal.BlockOffset, 2));

        byte[] oldBlockLast;
        uint oldBlockLastIndex;
        if (oldStopBlockIndex == oldBlockHeadIndex)
        {
            oldBlockLast = oldBlockHead;
            oldBlockLastIndex = oldBlockHeadIndex;
        }
        else
        {
            if (!ReadBlock(oldStopBlockIndex, oldCaches[1].Block))
            {
                return 1;
            }

            oldCaches[1].BlockIndex = oldStopBlockIndex;
            oldCaches[1].Active = true;
            oldBlockLast = oldCaches[1].Block;
            oldBlockLastIndex = oldStopBlockIndex;
            oldUsed++;
        }

        byte[]? oldBlockItem = null;
        uint oldBlockItemIndex = 0;
        ushort oldItemOffset = 0;
        byte oldDirFile = 0;
        var indexBlock = oldBlockHeadIndex;
        while (true)
        {
            var k = FileSystemInternal.BlockHead;
            for (var i = 0; i < FileSystemInternal.BlockItemMaxCount; i++)
            {
                var state = oldBlock[k++];
                var entryName = FileSystemUtil.FixedNameToString(oldBlock.AsSpan(k, FileSystemInternal.BlockNameMaxSize));
                k += FileSystemInternal.BlockNameMaxSize;
                if (!string.Equals(entryName, oldLastName, StringComparison.Ordinal))
                {
                    k += 10;
                    if (indexBlock == oldStopBlockIndex && k + 1 >= oldOffset)
                    {
                        return 4;
                    }

                    continue;
                }

                oldDirFile = (byte)(state & 0x01);
                if (oldTypeDir == 1 && oldDirFile == 1)
                {
                    return 2;
                }

                if (newTypeDir == 1 && oldDirFile == 1)
                {
                    return 6;
                }

                oldItemOffset = (ushort)(k + 10);
                for (var j = 0; j < oldUsed; j++)
                {
                    if (oldCaches[j].BlockIndex != indexBlock)
                    {
                        continue;
                    }

                    oldBlockItem = oldCaches[j].Block;
                    oldBlockItemIndex = indexBlock;
                    break;
                }

                if (oldBlockItem is null)
                {
                    Array.Copy(oldBlock, oldCaches[oldUsed].Block, oldBlock.Length);
                    oldCaches[oldUsed].BlockIndex = indexBlock;
                    oldCaches[oldUsed].Active = true;
                    oldBlockItem = oldCaches[oldUsed].Block;
                    oldBlockItemIndex = indexBlock;
                    oldUsed++;
                }

                goto FoundOldEntry;
            }

            indexBlock = FileSystemUtil.ReadUInt32(oldBlock.AsSpan(4, 4));
            if (indexBlock == 0 || !ReadBlock(indexBlock, oldBlock))
            {
                return 1;
            }
        }

    FoundOldEntry:
        var newCaches = new[] { new BlockCache(), new BlockCache() };
        var newUsed = 1;
        var newBlock = new byte[FileSystemInternal.BlockSize];
        if (!ReadBlock(newBlockIndex, newBlock))
        {
            return 1;
        }

        Array.Copy(newBlock, newCaches[0].Block, newBlock.Length);
        newCaches[0].BlockIndex = newBlockIndex;
        newCaches[0].Active = true;
        var newBlockHead = newCaches[0].Block;
        var newBlockHeadIndex = newBlockIndex;
        var newStopBlockIndex = FileSystemUtil.ReadUInt32(newBlockHead.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4));
        var newOffset = FileSystemUtil.ReadUInt16(newBlockHead.AsSpan(FileSystemInternal.BlockOffset, 2));

        byte[] newBlockLast;
        uint newBlockLastIndex;
        if (newStopBlockIndex == newBlockHeadIndex)
        {
            newBlockLast = newBlockHead;
            newBlockLastIndex = newBlockHeadIndex;
        }
        else
        {
            if (!ReadBlock(newStopBlockIndex, newCaches[1].Block))
            {
                return 1;
            }

            newCaches[1].BlockIndex = newStopBlockIndex;
            newCaches[1].Active = true;
            newBlockLast = newCaches[1].Block;
            newBlockLastIndex = newStopBlockIndex;
            newUsed++;
        }

        indexBlock = newBlockHeadIndex;
        while (true)
        {
            var k = FileSystemInternal.BlockHead;
            for (var i = 0; i < FileSystemInternal.BlockItemMaxCount; i++)
            {
                k++;
                var entryName = FileSystemUtil.FixedNameToString(newBlock.AsSpan(k, FileSystemInternal.BlockNameMaxSize));
                k += FileSystemInternal.BlockNameMaxSize;
                if (!string.Equals(entryName, newLastName, StringComparison.Ordinal))
                {
                    k += 10;
                    if (indexBlock == newStopBlockIndex && k + 1 >= newOffset)
                    {
                        goto DestinationReady;
                    }

                    continue;
                }

                return 5;
            }

            indexBlock = FileSystemUtil.ReadUInt32(newBlock.AsSpan(4, 4));
            if (indexBlock == 0 || !ReadBlock(indexBlock, newBlock))
            {
                return 1;
            }
        }

    DestinationReady:
        var autoCommit = _tmp.State == 0;
        if (autoCommit && !StartTransaction(1))
        {
            return 1;
        }

        if (oldBlockHeadIndex == newBlockHeadIndex)
        {
            FileSystemUtil.CopyName(oldBlockItem!.AsSpan(oldItemOffset - 24, FileSystemInternal.BlockNameMaxSize), newLastName);
            if (!WriteBlock(oldBlockItemIndex, oldBlockItem))
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }

            if (autoCommit)
            {
                Commit();
            }

            return 0;
        }

        if (oldDirFile == 0)
        {
            var pathBlockIndex = FileSystemUtil.ReadUInt32(oldBlockItem!.AsSpan(oldItemOffset - 10, 4));
            var pathBlock = new byte[FileSystemInternal.BlockSize];
            if (!ReadBlock(pathBlockIndex, pathBlock))
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }

            FileSystemUtil.WriteUInt32(pathBlock.AsSpan(FileSystemInternal.BlockHead + 25 + 1 + 14, 4), newBlockHeadIndex);
            if (!WriteBlock(pathBlockIndex, pathBlock))
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }
        }

        byte[]? newTailBlock = null;
        uint newTailBlockIndex = 0;
        if (newOffset < FileSystemInternal.BlockSize)
        {
            Array.Copy(oldBlockItem!, oldItemOffset - 25, newBlockLast, newOffset, 25);
            FileSystemUtil.CopyName(newBlockLast.AsSpan(newOffset + 1, FileSystemInternal.BlockNameMaxSize), newLastName);
            newOffset += 25;
            FileSystemUtil.WriteUInt16(newBlockHead.AsSpan(FileSystemInternal.BlockOffset, 2), newOffset);
        }
        else
        {
            newTailBlockIndex = GenerateBlockIndex();
            if (newTailBlockIndex == 0)
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }

            newTailBlock = new byte[FileSystemInternal.BlockSize];
            FileSystemUtil.WriteUInt32(newTailBlock.AsSpan(8, 4), newBlockLastIndex);
            Array.Copy(oldBlockItem!, oldItemOffset - 25, newTailBlock, FileSystemInternal.BlockHead, 25);
            FileSystemUtil.CopyName(newTailBlock.AsSpan(FileSystemInternal.BlockHead + 1, FileSystemInternal.BlockNameMaxSize), newLastName);

            if (!WriteBlock(newTailBlockIndex, newTailBlock))
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }

            FileSystemUtil.WriteUInt32(newBlockLast.AsSpan(4, 4), newTailBlockIndex);
            newOffset = FileSystemInternal.BlockHead + 25;
            FileSystemUtil.WriteUInt16(newBlockHead.AsSpan(FileSystemInternal.BlockOffset, 2), newOffset);
            FileSystemUtil.WriteUInt32(newBlockHead.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4), newTailBlockIndex);
        }

        for (var i = 0; i < newUsed; i++)
        {
            if (newCaches[i].Active && !WriteBlock(newCaches[i].BlockIndex, newCaches[i].Block))
            {
                if (autoCommit)
                {
                    StopTransaction();
                }

                return 1;
            }
        }

        if (oldBlockItemIndex != oldStopBlockIndex || oldItemOffset != oldOffset)
        {
            Array.Copy(oldBlockLast, oldOffset - 25, oldBlockItem!, oldItemOffset - 25, 25);
        }

        oldOffset -= 25;
        FileSystemUtil.WriteUInt16(oldBlockHead.AsSpan(FileSystemInternal.BlockOffset, 2), oldOffset);

        if (oldOffset < 25)
        {
            var oldBlockPrevIndex = FileSystemUtil.ReadUInt32(oldBlockLast.AsSpan(8, 4));
            RemoveBlock(oldBlockLastIndex);
            var freedSlot = -1;
            for (var i = 0; i < oldUsed; i++)
            {
                if (oldCaches[i].BlockIndex != oldBlockLastIndex)
                {
                    continue;
                }

                oldCaches[i].Active = false;
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

            byte[]? oldBlockPrev = null;
            for (var i = 0; i < oldUsed; i++)
            {
                if (oldCaches[i].BlockIndex != oldBlockPrevIndex)
                {
                    continue;
                }

                oldBlockPrev = oldCaches[i].Block;
                break;
            }

            if (oldBlockPrev is null)
            {
                if (!ReadBlock(oldBlockPrevIndex, oldBlock))
                {
                    if (autoCommit)
                    {
                        StopTransaction();
                    }

                    return 1;
                }

                Array.Copy(oldBlock, oldCaches[freedSlot].Block, oldBlock.Length);
                oldCaches[freedSlot].BlockIndex = oldBlockPrevIndex;
                oldCaches[freedSlot].Active = true;
                oldBlockPrev = oldCaches[freedSlot].Block;
            }

            oldBlockPrev.AsSpan(4, 4).Clear();
            FileSystemUtil.WriteUInt32(oldBlockHead.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4), oldBlockPrevIndex);
            FileSystemUtil.WriteUInt16(oldBlockHead.AsSpan(FileSystemInternal.BlockOffset, 2), FileSystemInternal.BlockSize);
        }

        for (var i = 0; i < oldUsed; i++)
        {
            if (oldCaches[i].Active && !WriteBlock(oldCaches[i].BlockIndex, oldCaches[i].Block))
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
}
