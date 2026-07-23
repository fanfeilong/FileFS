namespace FileFS;

public sealed partial class FileSystem
{
    public void Chdir(string path)
    {
        EnsureMounted();
        if (!TryChdir(path))
        {
            throw Error($"Directory '{path}' does not exist.");
        }
    }

    public string Getcwd()
    {
        EnsureMounted();
        return CurrentPwd;
    }

    public bool FileExists(string path)
    {
        EnsureMounted();
        return Stat(path) == 1;
    }

    public bool DirExists(string path)
    {
        EnsureMounted();
        return Stat(path) == 2;
    }

    private bool InitPwdTmp(string value)
    {
        _pwdTmp = value;
        return true;
    }

    private bool AddToPwdTmp(string segment)
    {
        if (segment == ".")
        {
            return true;
        }

        if (segment == "..")
        {
            for (var i = 1; i < _pwdTmp.Length; i++)
            {
                var slashIndex = _pwdTmp.Length - i - 1;
                if (_pwdTmp[slashIndex] == '/')
                {
                    _pwdTmp = _pwdTmp[..(_pwdTmp.Length - i)];
                    return true;
                }
            }

            return false;
        }

        _pwdTmp += segment + "/";
        return true;
    }

    private bool TryChdir(string path)
    {
        if (!IsMounted)
        {
            return false;
        }

        path ??= string.Empty;
        uint blockIndex;
        var start = 0;
        if (path.Length > 0 && path[0] == '/')
        {
            blockIndex = 1;
            start = 1;
            if (!InitPwdTmp("/"))
            {
                return false;
            }
        }
        else
        {
            blockIndex = CurrentPwdBlockIndex;
            if (!InitPwdTmp(CurrentPwd))
            {
                return false;
            }
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
                    return false;
                }

                blockIndex = index;
                if (!AddToPwdTmp(new string(segment[..segmentLength])))
                {
                    return false;
                }

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
            var index = FindPathBlockIndex(blockIndex, new string(segment[..segmentLength]));
            if (index < 1)
            {
                return false;
            }

            blockIndex = index;
            if (!AddToPwdTmp(new string(segment[..segmentLength])))
            {
                return false;
            }
        }

        if (_tmp.State == 0)
        {
            _pwd = _pwdTmp;
            _pwdBlockIndex = blockIndex;
        }
        else
        {
            _tmp.Pwd = _pwdTmp;
            _tmp.PwdBlockIndex = blockIndex;
        }

        return true;
    }

    private byte Stat(string name)
    {
        if (string.IsNullOrEmpty(name) || !IsMounted)
        {
            return 0;
        }

        uint blockIndex;
        var start = 0;
        if (name[0] == '/')
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
        for (var i = start; i < name.Length; i++)
        {
            if (name[i] == '/')
            {
                if (segmentLength == 0)
                {
                    continue;
                }

                var index = FindPathBlockIndex(blockIndex, new string(segment[..segmentLength]));
                if (index < 1)
                {
                    return 0;
                }

                blockIndex = index;
                segmentLength = 0;
                continue;
            }

            if (segmentLength >= FileSystemInternal.BlockNameMaxSize)
            {
                return 0;
            }

            segment[segmentLength++] = name[i];
        }

        if (segmentLength == 0)
        {
            return 2;
        }

        var lastName = new string(segment[..segmentLength]);
        var block = new byte[FileSystemInternal.BlockSize];
        if (!ReadBlock(blockIndex, block))
        {
            return 0;
        }

        var stopBlockIndex = FileSystemUtil.ReadUInt32(block.AsSpan(FileSystemInternal.BlockStopBlockIndex, 4));
        var offset = FileSystemUtil.ReadUInt16(block.AsSpan(FileSystemInternal.BlockOffset, 2));

        var indexBlock = blockIndex;
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
                        return 0;
                    }

                    continue;
                }

                return (byte)(((state & 0x01) == 0) ? 2 : 1);
            }

            indexBlock = FileSystemUtil.ReadUInt32(block.AsSpan(4, 4));
            if (indexBlock == 0 || !ReadBlock(indexBlock, block))
            {
                return 0;
            }
        }
    }
}
