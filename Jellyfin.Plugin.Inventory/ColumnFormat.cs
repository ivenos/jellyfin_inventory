namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// How the browser should render a column's values.
/// </summary>
public enum ColumnFormat
{
    /// <summary>Plain text.</summary>
    Text,

    /// <summary>An integer or decimal number.</summary>
    Number,

    /// <summary>A number that is an identifier rather than a quantity, printed without digit grouping.</summary>
    Plain,

    /// <summary>A byte count.</summary>
    Bytes,

    /// <summary>A byte count per hour of runtime.</summary>
    BytesPerHour,

    /// <summary>A duration in seconds.</summary>
    Duration,

    /// <summary>A bitrate in bits per second.</summary>
    Bitrate,

    /// <summary>A frame rate.</summary>
    FrameRate,

    /// <summary>A date.</summary>
    Date,

    /// <summary>A boolean.</summary>
    Boolean
}
