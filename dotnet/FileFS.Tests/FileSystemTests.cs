using System.Text;

namespace FileFS.Tests;

public sealed class FileSystemTests
{
    [Fact]
    public void MkfsMountAndGetcwd()
    {
        using var fixture = new TempFsFixture();
        Assert.Equal("/", fixture.FileSystem.Getcwd());
    }

    [Fact]
    public void MkdirAndChdir()
    {
        using var fixture = new TempFsFixture();

        fixture.FileSystem.Mkdir("docs");
        fixture.FileSystem.Chdir("docs");

        Assert.Equal("/docs/", fixture.FileSystem.Getcwd());
    }

    [Fact]
    public void OpenWriteReadRoundtrip()
    {
        using var fixture = new TempFsFixture();

        using (var file = fixture.FileSystem.Open("note.txt", "w"))
        {
            var payload = Encoding.ASCII.GetBytes("hello filefs");
            Assert.Equal(payload.Length, fixture.FileSystem.Write(file, payload));
        }

        using var reader = fixture.FileSystem.Open("note.txt", "r");
        var buffer = new byte[64];
        var read = fixture.FileSystem.Read(reader, buffer);
        Assert.Equal("hello filefs", Encoding.ASCII.GetString(buffer, 0, read));
    }

    [Fact]
    public void CopyRenameAndRemove()
    {
        using var fixture = new TempFsFixture();

        using (var file = fixture.FileSystem.Open("note.txt", "w"))
        {
            Assert.Equal(3, fixture.FileSystem.Write(file, "abc"u8));
        }

        fixture.FileSystem.CopyFile("note.txt", "copy.txt");
        fixture.FileSystem.Rename("copy.txt", "renamed.txt");
        fixture.FileSystem.RemoveFile("renamed.txt");

        Assert.False(fixture.FileSystem.FileExists("renamed.txt"));
        Assert.True(fixture.FileSystem.FileExists("note.txt"));
    }

    [Fact]
    public void OpenDirListsDocs()
    {
        using var fixture = new TempFsFixture();

        fixture.FileSystem.Mkdir("docs");

        using var dir = fixture.FileSystem.OpenDir("/");
        var names = new List<string>();
        DirEntry? entry;
        while ((entry = fixture.FileSystem.ReadDir(dir)) is not null)
        {
            names.Add(entry.Name);
        }

        Assert.Contains("docs", names);
    }

    [Fact]
    public void BeginCommitCreatesFile()
    {
        using var fixture = new TempFsFixture();

        Assert.True(fixture.FileSystem.Begin());
        using (var file = fixture.FileSystem.Open("txn.txt", "w"))
        {
            Assert.Equal(1, fixture.FileSystem.Write(file, "x"u8));
        }

        Assert.True(fixture.FileSystem.Commit());
        Assert.True(fixture.FileSystem.FileExists("txn.txt"));
    }

    private sealed class TempFsFixture : IDisposable
    {
        public TempFsFixture()
        {
            ImagePath = Path.GetTempFileName();
            FileSystem.Mkfs(ImagePath);
            FileSystem = new FileSystem();
            FileSystem.Mount(ImagePath);
        }

        public string ImagePath { get; }

        public FileSystem FileSystem { get; }

        public void Dispose()
        {
            FileSystem.Dispose();

            if (File.Exists(ImagePath))
            {
                File.Delete(ImagePath);
            }

            var journalPath = ImagePath + "-j";
            if (File.Exists(journalPath))
            {
                File.Delete(journalPath);
            }
        }
    }
}
