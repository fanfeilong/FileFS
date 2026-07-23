using System.IO;

namespace FileFS;

public sealed class FileFsException : IOException
{
    public FileFsException(string message)
        : base(message)
    {
    }

    public FileFsException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
