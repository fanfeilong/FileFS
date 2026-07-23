using System.IO;

namespace FileFS;

public sealed partial class FileSystem : IDisposable, IAsyncDisposable
{
    private string _path = string.Empty;
    private string _journalPath = string.Empty;
    private FileStream? _stream;
    private readonly TransactionContext _tmp = new();
    private string _pwd = string.Empty;
    private uint _pwdBlockIndex;
    private string _pwdTmp = string.Empty;

    public bool IsMounted => _stream is not null;

    public void Dispose()
    {
        Umount();
        GC.SuppressFinalize(this);
    }

    public ValueTask DisposeAsync()
    {
        Umount();
        GC.SuppressFinalize(this);
        return ValueTask.CompletedTask;
    }

    private FileStream Stream => _stream ?? throw new FileFsException("FileFS image is not mounted.");

    private uint CurrentPwdBlockIndex => _tmp.State == 0 ? _pwdBlockIndex : _tmp.PwdBlockIndex;

    private string CurrentPwd => _tmp.State == 0 ? _pwd : _tmp.Pwd;

    private static FileFsException Error(string message) => new(message);

    private static void Ensure(bool condition, string message)
    {
        if (!condition)
        {
            throw Error(message);
        }
    }

    private void EnsureMounted()
    {
        if (!IsMounted)
        {
            throw Error("FileFS image is not mounted.");
        }
    }

    private static byte ParseMode(string mode) => mode switch
    {
        "r" => 0,
        "w" => 1,
        "a" => 2,
        "r+" => 3,
        "w+" => 4,
        "a+" => 5,
        _ => throw new ArgumentException($"Unsupported mode '{mode}'.", nameof(mode)),
    };
}
