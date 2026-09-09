namespace Jellyfin.Plugin.Inventory.Configuration;

/// <summary>
/// How far a media type is expanded when it opens.
/// </summary>
public class ExpandPreference
{
    /// <summary>
    /// Gets or sets the media type.
    /// </summary>
    public string MediaType { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the deepest level shown.
    /// </summary>
    public string Level { get; set; } = string.Empty;
}
