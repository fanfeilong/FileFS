using System.IO;

namespace FileFS;

internal static class FileSystemInternal
{
    internal const int BlockSize = 512;
    internal const int BlockItemMaxCount = 20;
    internal const int BlockHead = 12;
    internal const int BlockNameMaxSize = 14;
    internal const int BlockStartBlockIndex = 27;
    internal const int BlockStopBlockIndex = 31;
    internal const int BlockOffset = 35;

    internal static ReadOnlySpan<byte> MagicNumber => [0x78, 0x11, 0x45, 0x14];
}

internal sealed class TransactionContext
{
    public byte State { get; set; }

    public string Pwd { get; set; } = string.Empty;

    public uint PwdBlockIndex { get; set; }

    public FileStream? CopyStream { get; set; }

    public FileStream? AddStream { get; set; }

    public string CopyPath { get; set; } = string.Empty;

    public string AddPath { get; set; } = string.Empty;

    public uint CopySize { get; set; }

    public uint TotalBlockSize { get; set; }

    public uint UnusedBlockHead { get; set; }

    public uint NewTotalBlockSize { get; set; }

    public uint NewUnusedBlockHead { get; set; }
}

internal sealed class BlockCache
{
    public bool Active { get; set; }

    public byte[] Block { get; } = new byte[FileSystemInternal.BlockSize];

    public uint BlockIndex { get; set; }
}
