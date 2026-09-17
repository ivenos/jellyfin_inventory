using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// A condition a row has to meet on one column.
/// </summary>
public sealed class RowFilter
{
    /// <summary>
    /// The most conditions one request may carry.
    /// </summary>
    public const int MaxCount = 20;

    private static readonly (string Name, FilterOperator Operator)[] _operators =
    [
        ("ge", FilterOperator.AtLeast),
        ("le", FilterOperator.AtMost),
        ("eq", FilterOperator.Equal),
        ("ne", FilterOperator.NotEqual),
        ("contains", FilterOperator.Contains),
        ("notContains", FilterOperator.NotContains),
        ("empty", FilterOperator.Empty),
        ("notEmpty", FilterOperator.NotEmpty)
    ];

    private readonly object? _value;

    private RowFilter(ColumnDefinition column, FilterOperator op, object? value)
    {
        Column = column;
        Operator = op;
        _value = value;
    }

    /// <summary>
    /// Gets the column the condition is on.
    /// </summary>
    public ColumnDefinition Column { get; }

    /// <summary>
    /// Gets how the cell is held against the value.
    /// </summary>
    public FilterOperator Operator { get; }

    /// <summary>
    /// Gets the operators a column of a format can be filtered with, the one offered first in front.
    /// </summary>
    /// <param name="format">The column format.</param>
    /// <returns>The operators, as they are named in a request.</returns>
    public static IReadOnlyList<string> Operators(ColumnFormat format) => format switch
    {
        ColumnFormat.Text => ["contains", "notContains", "eq", "ne", "empty", "notEmpty"],
        ColumnFormat.Boolean => ["eq", "empty", "notEmpty"],
        // Shown rounded to a unit, so a value typed from the table never equals the one kept.
        ColumnFormat.Bytes or ColumnFormat.BytesPerHour or ColumnFormat.Duration or ColumnFormat.Bitrate
            => ["ge", "le", "empty", "notEmpty"],
        _ => ["ge", "le", "eq", "ne", "empty", "notEmpty"]
    };

    /// <summary>
    /// Reads the conditions of a request: a JSON array of objects with "column", "op" and, unless
    /// the operator asks whether the cell is empty, "value".
    /// </summary>
    /// <param name="json">The array, or nothing for no conditions.</param>
    /// <param name="error">What is wrong with it, or null.</param>
    /// <returns>The conditions, which are none where there is an error.</returns>
    public static IReadOnlyList<RowFilter> Parse(string? json, out string? error)
    {
        error = null;
        if (string.IsNullOrWhiteSpace(json))
        {
            return [];
        }

        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Array
                || document.RootElement.GetArrayLength() > MaxCount)
            {
                error = $"filters has to be a JSON array of at most {MaxCount} conditions.";
                return [];
            }

            var filters = new List<RowFilter>();
            foreach (var entry in document.RootElement.EnumerateArray())
            {
                if (Read(entry, out error) is not { } filter)
                {
                    return [];
                }

                filters.Add(filter);
            }

            return filters;
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException)
        {
            // An escaped lone surrogate parses, and only throws once it is read as a string.
            error = "filters is not valid JSON.";
            return [];
        }
    }

    /// <summary>
    /// Tells whether a row meets the condition. An empty cell meets only a negated one or the one
    /// asking for it, and a cell that reads as mixed meets none, since it may go either way.
    /// </summary>
    /// <param name="row">The row.</param>
    /// <returns>Whether the row stays.</returns>
    public bool Matches(InventoryRow row)
    {
        ArgumentNullException.ThrowIfNull(row);
        if (row.Mixed?.Contains(Column.Key) == true)
        {
            return false;
        }

        var cell = Column.Value(row);
        var blank = cell is null or string { Length: 0 };
        if (Operator is FilterOperator.Empty or FilterOperator.NotEmpty)
        {
            return blank == (Operator == FilterOperator.Empty);
        }

        if (blank)
        {
            return Operator is FilterOperator.NotEqual or FilterOperator.NotContains;
        }

        return Operator switch
        {
            FilterOperator.Contains => Holds(cell!),
            FilterOperator.NotContains => !Holds(cell!),
            FilterOperator.Equal => Compare(cell!) == 0,
            FilterOperator.NotEqual => Compare(cell!) != 0,
            FilterOperator.AtLeast => Compare(cell!) >= 0,
            _ => Compare(cell!) <= 0
        };
    }

    private static RowFilter? Read(JsonElement entry, out string? error)
    {
        var key = entry.ValueKind == JsonValueKind.Object ? Text(entry, "column") : null;
        if (Columns.Find(key) is not { } column)
        {
            error = $"'{key}' is not a column.";
            return null;
        }

        var name = Text(entry, "op");
        var known = _operators.FirstOrDefault(o => string.Equals(o.Name, name, StringComparison.Ordinal));
        if (known.Name is null || !Operators(column.Format).Contains(known.Name))
        {
            error = $"'{name}' is not an operator for '{column.Key}'.";
            return null;
        }

        if (known.Operator is FilterOperator.Empty or FilterOperator.NotEmpty)
        {
            error = null;
            return new RowFilter(column, known.Operator, null);
        }

        var text = Text(entry, "value");
        object? value = column.Format switch
        {
            ColumnFormat.Text => string.IsNullOrEmpty(text) ? null : text,
            ColumnFormat.Boolean => bool.TryParse(text, out var flag) ? flag : null,
            ColumnFormat.Date => DateTime.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day) ? day : null,
            _ => double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) && double.IsFinite(number) ? number : null
        };

        error = value is null ? $"'{text}' is not a value for '{column.Key}'." : null;
        return value is null ? null : new RowFilter(column, known.Operator, value);
    }

    private static string? Text(JsonElement entry, string property)
        => entry.TryGetProperty(property, out var found)
            ? found.ValueKind switch
            {
                JsonValueKind.String => found.GetString(),
                JsonValueKind.Number => found.GetRawText(),
                JsonValueKind.True => "true",
                JsonValueKind.False => "false",
                _ => null
            }
            : null;

    private bool Holds(object cell)
        => (cell.ToString() ?? string.Empty).Contains((string)_value!, StringComparison.OrdinalIgnoreCase);

    private int Compare(object cell) => _value switch
    {
        string text => string.Compare(cell.ToString(), text, StringComparison.OrdinalIgnoreCase),
        bool flag => cell is bool held ? held.CompareTo(flag) : -1,
        // The day the table shows, which is the one the server keeps and not the browser's.
        DateTime day => cell is DateTime held ? held.Date.CompareTo(day) : -1,
        // To the digits the table shows, or 23.976 never equals the 23.976025 it is kept as.
        double number => Math.Round(Convert.ToDouble(cell, CultureInfo.InvariantCulture), 3).CompareTo(Math.Round(number, 3)),
        _ => -1
    };
}
