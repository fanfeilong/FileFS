namespace FileFS;

public sealed class FileHandle : IDisposable
{
    private FileSystem? _owner;

    internal FileHandle(FileSystem owner)
    {
        _owner = owner;
    }

    internal byte Mode { get; set; }

    internal uint DirBlockIndex { get; set; }

    internal ushort DirOffset { get; set; }

    internal uint FileStartBlockIndex { get; set; }

    internal uint FileStopBlockIndex { get; set; }

    internal ushort FileOffset { get; set; }

    internal uint PosBlockIndex { get; set; }

    internal ushort PosOffset { get; set; }

    internal ulong Pos { get; set; }

    internal bool IsClosed => _owner is null;

    public void Dispose()
    {
        var owner = _owner;
        if (owner is null)
        {
            return;
        }

        _owner = null;
        owner.Close(this);
    }
}
