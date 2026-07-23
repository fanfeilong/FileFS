namespace FileFS;

public sealed class DirectoryHandle : IDisposable
{
    private FileSystem? _owner;

    internal DirectoryHandle(FileSystem owner)
    {
        _owner = owner;
        Block = new byte[FileSystemInternal.BlockSize];
    }

    internal byte[] Block { get; }

    internal int SearchIndex { get; set; }

    internal uint BlockIndex { get; set; }

    internal uint StopBlockIndex { get; set; }

    internal ushort Offset { get; set; }

    internal DirEntry CachedEntry { get; } = new();

    internal bool IsClosed => _owner is null;

    public void Dispose()
    {
        var owner = _owner;
        if (owner is null)
        {
            return;
        }

        _owner = null;
        owner.CloseDir(this);
    }
}
