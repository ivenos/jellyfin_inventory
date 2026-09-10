using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security;
using System.Text;
using System.Threading;
using System.Xml;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// Turns a page of rows into a file a spreadsheet can open.
/// </summary>
public static class Export
{
    /// <summary>
    /// Writes the rows as comma separated values.
    /// </summary>
    /// <param name="output">The stream the file is written to.</param>
    /// <param name="columns">The columns, in order.</param>
    /// <param name="headers">The translated header for each column.</param>
    /// <param name="rows">The rows to write.</param>
    /// <param name="culture">The culture the numbers are written in, as the spreadsheet expects
    /// them, which is the one asked for rather than the one the headers fell back to.</param>
    /// <param name="yes">The word for a value that is true, in that same culture.</param>
    /// <param name="no">The word for a value that is false.</param>
    /// <param name="cancellation">Stops reading rows once the caller has gone away.</param>
    public static void Csv(
        Stream output,
        IReadOnlyList<ColumnDefinition> columns,
        IReadOnlyList<string> headers,
        IEnumerable<InventoryRowResult> rows,
        CultureInfo culture,
        string yes,
        string no,
        CancellationToken cancellation)
    {
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(culture);

        // Where a comma is the decimal separator it cannot also separate the fields.
        var separator = string.Equals(culture.NumberFormat.NumberDecimalSeparator, ",", StringComparison.Ordinal)
            ? ';'
            : ',';

        // The BOM is what makes Excel read it as UTF-8 rather than the local codepage.
        output.Write(Encoding.UTF8.GetPreamble());

        using var writer = new StreamWriter(output, new UTF8Encoding(false), 64 * 1024, leaveOpen: true) { NewLine = "\r\n" };
        writer.WriteLine(string.Join(separator, Quote(headers.Select(Literal), separator)));

        foreach (var row in rows)
        {
            cancellation.ThrowIfCancellationRequested();
            var values = new List<string>(columns.Count);
            foreach (var column in columns)
            {
                values.Add(Scalar(row.Values.GetValueOrDefault(column.Key), culture, yes, no));
            }

            writer.WriteLine(string.Join(separator, Quote(values, separator)));
        }
    }

    /// <summary>
    /// Writes the rows as an OpenDocument spreadsheet, with numbers and dates typed so they can be
    /// sorted and totalled without being converted first.
    /// </summary>
    /// <param name="output">The stream the file is written to.</param>
    /// <param name="columns">The columns, in order.</param>
    /// <param name="headers">The translated header for each column.</param>
    /// <param name="rows">The rows to write.</param>
    /// <param name="sheetName">The name of the single sheet.</param>
    /// <param name="yes">The word for a value that is true, in the culture of the headers.</param>
    /// <param name="no">The word for a value that is false.</param>
    /// <param name="cancellation">Stops reading rows once the caller has gone away.</param>
    public static void Ods(
        Stream output,
        IReadOnlyList<ColumnDefinition> columns,
        IReadOnlyList<string> headers,
        IEnumerable<InventoryRowResult> rows,
        string sheetName,
        string yes,
        string no,
        CancellationToken cancellation)
    {
        ArgumentNullException.ThrowIfNull(output);

        using (var archive = new ZipArchive(output, ZipArchiveMode.Create, true))
        {
            // The mimetype entry has to come first and be stored, not deflated.
            var mimetype = archive.CreateEntry("mimetype", CompressionLevel.NoCompression);
            using (var writer = new StreamWriter(mimetype.Open()))
            {
                writer.Write("application/vnd.oasis.opendocument.spreadsheet");
            }

            Write(archive, "META-INF/manifest.xml", Manifest());

            using var content = new StreamWriter(archive.CreateEntry("content.xml").Open());
            Content(content, columns, headers, rows, sheetName, yes, no, cancellation);
        }
    }

    private static void Write(ZipArchive archive, string path, string content)
    {
        using var writer = new StreamWriter(archive.CreateEntry(path).Open());
        writer.Write(content);
    }

    private static IEnumerable<string> Quote(IEnumerable<string> values, char separator)
    {
        foreach (var value in values)
        {
            yield return value.AsSpan().IndexOfAny([separator, '"', '\n', '\r']) >= 0
                ? '"' + value.Replace("\"", "\"\"", StringComparison.Ordinal) + '"'
                : value;
        }
    }

    private static string Scalar(object? value, CultureInfo culture, string yes, string no) => value switch
    {
        null => string.Empty,
        // The headers are translated and the numbers are local, so a truth value reads that way too.
        bool flag => flag ? yes : no,
        // The one date format every reader takes whatever it is set to.
        DateTime date => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        IFormattable number => number.ToString(null, culture),
        _ => Literal(Printable(value.ToString() ?? string.Empty))
    };

    // A cell a spreadsheet would read as a formula is prefixed, since a file name is not something
    // the person exporting chose.
    private static string Literal(string value)
        => value.Length > 0 && "=+-@\t\r".Contains(value[0], StringComparison.Ordinal) ? "'" + value : value;

    // A reader that dislikes a character in a sheet name does not say so, it calls the sheet
    // Sheet1 and moves on.
    private static string SheetName(string value)
    {
        var name = new string(Printable(value)
            .Where(c => "[]*?:/\\".IndexOf(c, StringComparison.Ordinal) < 0)
            .ToArray()).Trim();

        if (name.Length > 31)
        {
            name = name[..31].TrimEnd();
        }

        return name.Length > 0 ? name : "Inventory";
    }

    private static string Manifest() =>
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
          <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
          <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
        </manifest:manifest>
        """;

    private static void Content(
        TextWriter xml,
        IReadOnlyList<ColumnDefinition> columns,
        IReadOnlyList<string> headers,
        IEnumerable<InventoryRowResult> rows,
        string sheetName,
        string yes,
        string no,
        CancellationToken cancellation)
    {
        xml.Write("""<?xml version="1.0" encoding="UTF-8"?>""");
        xml.Write("""<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" """);
        xml.Write("""xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" """);
        xml.Write("""xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" """);
        xml.Write("""xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" """);
        xml.Write("""xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0" """);
        xml.Write("""office:version="1.2">""");

        // A typed date without a format is shown as its serial number, which is what a reader
        // falls back to when the cell names no style.
        xml.Write("<office:automatic-styles>");
        xml.Write("""<number:date-style style:name="N-date"><number:year number:style="long"/>""");
        xml.Write("""<number:text>-</number:text><number:month number:style="long"/>""");
        xml.Write("""<number:text>-</number:text><number:day number:style="long"/></number:date-style>""");
        xml.Write("""<number:boolean-style style:name="N-bool"><number:boolean/></number:boolean-style>""");
        xml.Write("""<style:style style:name="C-date" style:family="table-cell" style:data-style-name="N-date"/>""");
        xml.Write("""<style:style style:name="C-bool" style:family="table-cell" style:data-style-name="N-bool"/>""");
        xml.Write("</office:automatic-styles>");
        xml.Write("<office:body><office:spreadsheet>");
        xml.Write(string.Create(CultureInfo.InvariantCulture, $"""<table:table table:name="{Escape(SheetName(sheetName))}">"""));

        // A table has to declare its columns before its rows, or the document does not validate.
        xml.Write(string.Create(CultureInfo.InvariantCulture, $"""<table:table-column table:number-columns-repeated="{columns.Count}"/>"""));

        xml.Write("<table:table-row>");
        foreach (var header in headers)
        {
            xml.Write(string.Create(CultureInfo.InvariantCulture, $"""<table:table-cell office:value-type="string"><text:p>{Escape(header)}</text:p></table:table-cell>"""));
        }

        xml.Write("</table:table-row>");

        foreach (var row in rows)
        {
            cancellation.ThrowIfCancellationRequested();
            xml.Write("<table:table-row>");
            foreach (var column in columns)
            {
                xml.Write(Cell(row.Values.GetValueOrDefault(column.Key), yes, no));
            }

            xml.Write("</table:table-row>");
        }

        xml.Write("</table:table></office:spreadsheet></office:body></office:document-content>");
    }

    private static string Cell(object? value, string yes, string no)
    {
        switch (value)
        {
            case null:
                return "<table:table-cell/>";
            case bool flag:
                // The text is what a reader that brings no format of its own puts on screen.
                var truth = flag ? "true" : "false";
                return string.Create(CultureInfo.InvariantCulture, $"""<table:table-cell table:style-name="C-bool" office:value-type="boolean" office:boolean-value="{truth}"><text:p>{Escape(flag ? yes : no)}</text:p></table:table-cell>""");
            case DateTime date:
                var stamp = date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                return string.Create(CultureInfo.InvariantCulture, $"""<table:table-cell table:style-name="C-date" office:value-type="date" office:date-value="{stamp}"><text:p>{stamp}</text:p></table:table-cell>""");
            case IFormattable number:
                var text = number.ToString(null, CultureInfo.InvariantCulture);
                return string.Create(CultureInfo.InvariantCulture, $"""<table:table-cell office:value-type="float" office:value="{text}"><text:p>{text}</text:p></table:table-cell>""");
            default:
                return string.Create(CultureInfo.InvariantCulture, $"""<table:table-cell office:value-type="string"><text:p>{Escape(value.ToString() ?? string.Empty)}</text:p></table:table-cell>""");
        }
    }

    private static string Escape(string value) => SecurityElement.Escape(Printable(value)) ?? string.Empty;

    // A name may hold anything the file system allows, and a character XML 1.0 cannot represent
    // would produce a spreadsheet no reader opens.
    private static string Printable(string value)
    {
        var text = new StringBuilder(value.Length);
        for (var i = 0; i < value.Length; i++)
        {
            if (i + 1 < value.Length && XmlConvert.IsXmlSurrogatePair(value[i + 1], value[i]))
            {
                text.Append(value[i]).Append(value[i + 1]);
                i++;
            }
            else if (XmlConvert.IsXmlChar(value[i]))
            {
                text.Append(value[i]);
            }
        }

        return text.ToString();
    }
}
