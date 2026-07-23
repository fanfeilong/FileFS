using System.Buffers.Binary;
using System.IO;
using System.Text;

namespace FileFS;

internal static class FileSystemUtil
{
    internal static uint ReadUInt32(ReadOnlySpan<byte> source)
        => BinaryPrimitives.ReadUInt32LittleEndian(source);

    internal static ushort ReadUInt16(ReadOnlySpan<byte> source)
        => BinaryPrimitives.ReadUInt16LittleEndian(source);

    internal static void WriteUInt32(Span<byte> destination, uint value)
        => BinaryPrimitives.WriteUInt32LittleEndian(destination, value);

    internal static void WriteUInt16(Span<byte> destination, ushort value)
        => BinaryPrimitives.WriteUInt16LittleEndian(destination, value);

    internal static bool ReadExact(FileStream stream, Span<byte> buffer)
    {
        var total = 0;
        while (total < buffer.Length)
        {
            var read = stream.Read(buffer[total..]);
            if (read <= 0)
            {
                return false;
            }

            total += read;
        }

        return true;
    }

    internal static void WriteExact(FileStream stream, ReadOnlySpan<byte> buffer)
    {
        stream.Write(buffer);
    }

    internal static void SetPosition(FileStream stream, long position)
    {
        stream.Seek(position, SeekOrigin.Begin);
    }

    internal static void Flush(FileStream stream)
    {
        stream.Flush(true);
    }

    internal static void Rewind(FileStream stream)
    {
        SetPosition(stream, 0);
    }

    internal static string FixedNameToString(ReadOnlySpan<byte> source)
    {
        var length = source.IndexOf((byte)0);
        if (length < 0)
        {
            length = source.Length;
        }

        return Encoding.ASCII.GetString(source[..length]);
    }

    internal static void CopyName(Span<byte> destination, string name)
    {
        destination.Clear();
        var bytes = Encoding.ASCII.GetBytes(name);
        bytes.AsSpan(0, Math.Min(bytes.Length, destination.Length)).CopyTo(destination);
    }
}
