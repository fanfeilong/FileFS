namespace FileFS;

public sealed class DirEntry
{
    public FileType Type { get; internal set; }

    public string Name { get; internal set; } = string.Empty;

    public int NameLength => Name.Length;
}
