# Reading a record stream

[System](index.md) · [Logs](logs.md) · [SELinux](selinux.md) · [Entrypoint
verification](entrypoint-verification.md) · **Reading a record stream** — [all
docs](../index.md)

Read the rows a report writes for a machine consumer, in the order they arrive,
from a .NET 10 program that treats the stream as bytes.

`ai-tools projects claim --format tsv`
and `ai-tools-admin system post-upgrade --check` write what they found
as a record stream on standard output: a header row, then one tab-separated row
per finding, each ending in a line feed. The contract is
`man 5 ai-tools-records`; this reads one as it arrives:

```bash
dotnet run ReadRecords.cs -- ai-tools projects claim --format tsv /srv/project
```

```csharp
// ReadRecords.cs -- read a record stream (ai-tools-records(5)) and print its rows.
using System.Diagnostics;
using System.Text;

var start = new ProcessStartInfo(args[0], args[1..]) { RedirectStandardOutput = true };
using var process = Process.Start(start)!;
using var captured = new MemoryStream();
// BaseStream hands over the bytes as written: no text decoder, no code page,
// no BOM detection.
process.StandardOutput.BaseStream.CopyTo(captured);
process.WaitForExit();

foreach (var row in RecordStream.Read(captured.ToArray()))
{
    // Display only: a path is bytes, and may not be UTF-8.
    var subject = Encoding.UTF8.GetString(row["subject"]);
    Console.WriteLine($"{Encoding.ASCII.GetString(row["severity"])}\t" +
                      $"{Encoding.ASCII.GetString(row["finding"])}\t{subject}");
}
Console.WriteLine($"exit {process.ExitCode}");
return process.ExitCode;

/// <summary>The FIELD ENCODING and ITEMS rules of ai-tools-records(5).
/// Each method throws FormatException on input the rules reject.</summary>
static class RecordStream
{
    static readonly string[] Canonical =
    [
        "observed-at", "occurred-at", "code", "record-id", "severity", "finding",
        "subject-type", "operator", "item", "subject", "detail",
    ];

    /// <summary>Returns one stream's rows as column-name-to-bytes maps, in
    /// stream order; empty for an empty stream.</summary>
    public static List<Dictionary<string, byte[]>> Read(ReadOnlySpan<byte> data)
    {
        var rows = new List<Dictionary<string, byte[]>>();
        if (data.IsEmpty) return rows;
        if (data[^1] != (byte)'\n') throw new FormatException("truncated final line");
        var lines = Split(data[..^1], (byte)'\n');
        var header = Split(lines[0], (byte)'\t').Select(cell =>
        {
            if (cell.AsSpan().ContainsAnyExceptInRange((byte)0x20, (byte)0x7e))
                throw new FormatException("no header");
            return Encoding.ASCII.GetString(cell);
        }).ToArray();
        if (header.Distinct().Count() != header.Length)
            throw new FormatException("duplicate column");
        if (Canonical.Any(column => !header.Contains(column)))
            throw new FormatException("missing canonical column");
        foreach (var line in lines.Skip(1))
        {
            var cells = Split(line, (byte)'\t');
            if (cells.Count != header.Length)
                throw new FormatException("field count differs from the header");
            var row = new Dictionary<string, byte[]>(header.Length);
            for (var i = 0; i < header.Length; i++) row[header[i]] = DecodeField(cells[i]);
            rows.Add(row);
        }
        return rows;
    }

    /// <summary>Returns the bytes one field encodes.</summary>
    public static byte[] DecodeField(ReadOnlySpan<byte> field)
    {
        if (field.ContainsAnyExceptInRange((byte)0x20, (byte)0x7e))
            throw new FormatException("raw byte outside 0x20-0x7e");
        var output = new List<byte>(field.Length);
        for (var i = 0; i < field.Length; i++)
        {
            if (field[i] != (byte)'\\') { output.Add(field[i]); continue; }
            if (i + 1 >= field.Length) throw new FormatException("truncated escape");
            switch (field[++i])
            {
                case (byte)'\\': output.Add((byte)'\\'); break;
                case (byte)'t': output.Add((byte)'\t'); break;
                case (byte)'n': output.Add((byte)'\n'); break;
                case (byte)'r': output.Add((byte)'\r'); break;
                case (byte)'x':
                    if (i + 2 >= field.Length || !IsLowerHex(field[i + 1]) || !IsLowerHex(field[i + 2]))
                        throw new FormatException("unknown or truncated escape");
                    var value = Convert.ToByte(Encoding.ASCII.GetString(field.Slice(i + 1, 2)), 16);
                    if (value == 0 || value is >= 0x20 and <= 0x7e || value is 0x09 or 0x0a or 0x0d)
                        throw new FormatException("escape for a byte with a shorter form");
                    output.Add(value);
                    i += 2;
                    break;
                default: throw new FormatException("unknown escape");
            }
        }
        return [.. output];
    }

    /// <summary>Returns an item's components; the empty field is the empty list.</summary>
    public static List<byte[]> DecodeItem(ReadOnlySpan<byte> field)
    {
        if (field.IsEmpty) return [];
        var parts = Split(DecodeField(field), (byte)'\t').Select(part => DecodeField(part)).ToList();
        if (parts.Any(part => part.Length == 0)) throw new FormatException("empty item component");
        return parts;
    }

    static bool IsLowerHex(byte b) => b is >= (byte)'0' and <= (byte)'9' or >= (byte)'a' and <= (byte)'f';

    static List<byte[]> Split(ReadOnlySpan<byte> data, byte separator)
    {
        var parts = new List<byte[]>();
        foreach (var range in data.Split(separator)) parts.Add(data[range].ToArray());
        return parts;
    }
}
```

The program starts the command with only its standard output redirected, reads
that output as bytes, decodes each row through the rules the manual states,
prints one line per row, and returns the command's exit status. Its standard
error is left alone, so the claim's page still reaches the terminal. To read
a stream saved earlier, pass `cat saved.tsv` in place of the command,
or replace the process with `File.ReadAllBytes`.

## Bytes, not text

The wire is printable ASCII plus the tab and the line feed: the producer writes
every other byte as an escape, so the stream does not carry a byte order mark
or any byte a code page could reinterpret. The example reads `BaseStream`
for that reason. Neither `Console.OutputEncoding`, the console code page
on Windows, nor the BOM detection a `StreamReader` performs touches the bytes,
and a raw byte outside that range is a defect the reader reports, where a text
decoder would have folded it into a character and hidden it.

A decoded `subject` is the path's bytes. `Encoding.UTF8.GetString` is
for display, and a path that is not UTF-8 shows a replacement character there,
so a consumer that stores or compares paths keeps the `byte[]`.

## Order

`ai-tools projects claim` writes its rows in the byte order of `subject`,
the same order on every filesystem, so the consumer reads them as they arrive
and does not sort. `StringComparer.Ordinal` over the decoded strings agrees
with that order for every character in the Basic Multilingual Plane,
and a comparison over the bytes (`ReadOnlySpan<byte>.SequenceCompareTo`) agrees
everywhere. The order `Directory.EnumerateFiles` returns and the order
a culture-sensitive `Array.Sort` produces are neither, so a consumer
that merges its own listing with the stream sorts the listing ordinally first.

## Exit status

The command exits 0 for a clean run, whose stream is empty, 4 when a finding
needs attention, 5 when the reading could not be made in full, and 1
when a step it was asked to perform failed. The example returns that status,
so a scheduler or a monitor reads the stream and the status together. Capturing
standard error as well needs a second reader on its own thread, since a child
whose pipe fills stops writing.
