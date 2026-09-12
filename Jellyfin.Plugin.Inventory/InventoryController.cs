using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Jellyfin.Database.Implementations.Entities;
using Jellyfin.Plugin.Inventory.Configuration;
using MediaBrowser.Common.Api;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Library;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// The API behind the inventory table.
/// </summary>
[ApiController]
[Authorize(Policy = Policies.RequiresElevation)]
[Route("Inventory")]
[Produces("application/json")]
public class InventoryController : ControllerBase
{
    private static readonly object _configLock = new();
    private readonly InventoryService _inventory;
    private readonly IUserManager _userManager;
    private readonly IApplicationPaths _paths;

    /// <summary>
    /// Initializes a new instance of the <see cref="InventoryController"/> class.
    /// </summary>
    /// <param name="inventory">Instance of the <see cref="InventoryService"/>.</param>
    /// <param name="userManager">Instance of the <see cref="IUserManager"/> interface.</param>
    /// <param name="paths">Instance of the <see cref="IApplicationPaths"/> interface.</param>
    public InventoryController(InventoryService inventory, IUserManager userManager, IApplicationPaths paths)
    {
        _inventory = inventory;
        _userManager = userManager;
        _paths = paths;
    }

    private static PluginConfiguration Configuration => Plugin.Instance?.Configuration ?? new PluginConfiguration();

    /// <summary>
    /// Gets the user asking, since the playback columns are theirs and nobody else's.
    /// </summary>
    private User? Caller
    {
        get
        {
            // An API key authenticates as administrator without a user, and carries the empty guid.
            var claim = HttpContext.User.FindFirst("Jellyfin-UserId")?.Value;
            return Guid.TryParse(claim, out var id) && !id.Equals(default) ? _userManager.GetUserById(id) : null;
        }
    }

    // Reading a playback record copies the whole set of rows, and the totals cost a query per user
    // on top, so a table that shows neither is answered from the shared set.
    private User? Reader(IReadOnlyList<ColumnDefinition> columns, string? sortBy)
        => Uses(columns, sortBy, ColumnSource.User) ? Caller : null;

    private static bool Uses(IReadOnlyList<ColumnDefinition> columns, string? sortBy, ColumnSource source)
        => columns.Any(c => c.Source == source) || Columns.Find(sortBy)?.Source == source;

    /// <summary>
    /// Gets the table's shape: the populated media types with their levels, every available column,
    /// and the interface strings, all in the requested culture.
    /// </summary>
    /// <param name="culture">The culture to translate into, as the web client reports it.</param>
    /// <response code="200">The table's shape.</response>
    /// <returns>The media types, columns and strings.</returns>
    [HttpGet("Schema")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public ActionResult<object> GetSchema([FromQuery] string? culture)
    {
        var config = Configuration;

        return Ok(new
        {
            MediaTypes = _inventory.GetMediaTypes(culture).Select(t => new
            {
                t.MediaType,
                t.Label,
                t.Count,
                t.Levels,
                ExpandedTo = config.GetExpandLevel(t.MediaType)
            }),
            Columns = Columns.All.Select(c => Describe(c, culture)),
            PageSize = Math.Clamp(config.PageSize, 1, PluginConfiguration.MaxPageSize),
            Culture = Translations.Resolve(culture),
            Strings = Translations.All(culture)
        });
    }

    /// <summary>
    /// Gets one page of rows.
    /// </summary>
    /// <param name="mediaType">The media type to list.</param>
    /// <param name="level">The level within it, or empty for the outermost.</param>
    /// <param name="parentIds">Comma separated ids; when given, only the children of those rows are
    /// returned, and the whole set comes back unpaged since it belongs to rows already on screen.</param>
    /// <param name="columnLevel">The level whose column selection to use, for children shown inside
    /// their parent's table. Defaults to the level being listed.</param>
    /// <param name="culture">The culture to translate the column headers into.</param>
    /// <param name="search">An optional substring the name, series or path must contain.</param>
    /// <param name="sortBy">The column to sort on.</param>
    /// <param name="descending">Whether to sort descending.</param>
    /// <param name="startIndex">The first row to return.</param>
    /// <param name="limit">How many rows to return.</param>
    /// <response code="200">The requested page.</response>
    /// <response code="400">The media type, level, column level or sort column is not known.</response>
    /// <returns>The page of rows.</returns>
    [HttpGet("Items")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public ActionResult<object> GetItems(
        [FromQuery] string mediaType,
        [FromQuery] string? level,
        [FromQuery] string? parentIds,
        [FromQuery] string? columnLevel,
        [FromQuery] string? culture,
        [FromQuery] string? search,
        [FromQuery] string? sortBy,
        [FromQuery] bool descending = false,
        [FromQuery] int startIndex = 0,
        [FromQuery] int? limit = null)
    {
        var config = Configuration;
        if (Hierarchy.Resolve(mediaType, level) is null)
        {
            return BadRequest($"Unknown media type '{mediaType}' or level '{level}'.");
        }

        var selection = string.IsNullOrEmpty(columnLevel)
            ? (string.IsNullOrEmpty(level) ? mediaType : level)
            : columnLevel;

        if (Hierarchy.Level(selection) is null)
        {
            return BadRequest($"'{columnLevel}' is not a level.");
        }

        if (!string.IsNullOrEmpty(sortBy) && Columns.Find(sortBy) is null)
        {
            return BadRequest($"'{sortBy}' is not a column.");
        }

        var columns = Columns.Resolve(config.GetColumns(selection), selection);

        // A Guid[] would only bind from a repeated parameter, so the ids arrive comma separated.
        var parents = parentIds?.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(id => Guid.TryParse(id, out var parsed) ? parsed : Guid.Empty)
            .ToArray();

        // One id short would answer with part of a level and look like the whole of it.
        if (parents is not null && (parents.Length == 0 || Array.IndexOf(parents, Guid.Empty) >= 0))
        {
            return BadRequest("parentIds has to be a comma separated list of item ids.");
        }

        var expanding = parents is { Length: > 0 };
        var page = _inventory.Query(
            mediaType,
            level,
            parents,
            Reader(columns, sortBy),
            Uses(columns, sortBy, ColumnSource.Everyone),
            columns,
            search,
            sortBy,
            descending,
            expanding ? 0 : Math.Max(0, startIndex),
            expanding ? int.MaxValue : Math.Clamp(limit ?? config.PageSize, 1, PluginConfiguration.MaxPageSize),
            culture);

        return Ok(new
        {
            page.Rows,
            page.TotalCount,
            page.TotalSize,
            page.TotalDuration,
            Columns = columns.Select(c => Describe(c, culture))
        });
    }

    /// <summary>
    /// Exports everything the filter matches, with the columns chosen for the level.
    /// </summary>
    /// <param name="mediaType">The media type to export.</param>
    /// <param name="level">The level to export, or empty for the outermost.</param>
    /// <param name="columnLevel">The level whose column selection to use. Defaults to the level
    /// being exported.</param>
    /// <param name="format">Either "csv" or "ods".</param>
    /// <param name="culture">The culture the headers appear in.</param>
    /// <param name="search">An optional substring to filter on.</param>
    /// <param name="sortBy">The column that decides the row order.</param>
    /// <param name="descending">Whether that order is reversed.</param>
    /// <response code="200">The spreadsheet.</response>
    /// <response code="400">The media type, level, column level, format or sort column is not known.</response>
    /// <returns>A file download.</returns>
    [HttpGet("Export")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult> GetExport(
        [FromQuery] string mediaType,
        [FromQuery] string? level,
        [FromQuery] string? columnLevel,
        [FromQuery] string format,
        [FromQuery] string? culture,
        [FromQuery] string? search,
        [FromQuery] string? sortBy,
        [FromQuery] bool descending = false)
    {
        var isOds = string.Equals(format, "ods", StringComparison.OrdinalIgnoreCase);
        if (!isOds && !string.Equals(format, "csv", StringComparison.OrdinalIgnoreCase))
        {
            return BadRequest($"Unknown format '{format}'.");
        }

        var kind = Hierarchy.Resolve(mediaType, level);
        if (kind is null)
        {
            return BadRequest($"Unknown media type '{mediaType}' or level '{level}'.");
        }

        var exported = kind.Value.ToString();
        var selection = string.IsNullOrEmpty(columnLevel) ? exported : columnLevel;
        if (Hierarchy.Level(selection) is null)
        {
            return BadRequest($"'{columnLevel}' is not a level.");
        }

        if (!string.IsNullOrEmpty(sortBy) && Columns.Find(sortBy) is null)
        {
            return BadRequest($"'{sortBy}' is not a column.");
        }

        var columns = Columns.Resolve(Configuration.GetColumns(selection), selection);
        var headers = columns.Select(c => Translations.Get(culture, "column." + c.Key)).ToArray();

        var page = _inventory.Query(
            mediaType,
            level,
            null,
            Reader(columns, sortBy),
            Uses(columns, sortBy, ColumnSource.Everyone),
            columns,
            search,
            sortBy,
            descending,
            0,
            int.MaxValue,
            culture,
            topmost: true);
        var name = Translations.Get(culture, "level." + exported);
        var yes = Translations.Get(culture, "Yes");
        var no = Translations.Get(culture, "No");
        var attachment = $"attachment; filename=inventory-{exported.ToLowerInvariant()}.{(isOds ? "ods" : "csv")}";

        // Written to a file first: a spreadsheet is filled in by seeking back over it, and a
        // failure halfway through still becomes an error rather than half a download.
        Directory.CreateDirectory(_paths.TempDirectory);
        using var spool = new FileStream(
            Path.Combine(_paths.TempDirectory, $"inventory-{Guid.NewGuid():N}.{(isOds ? "ods" : "csv")}"),
            new FileStreamOptions
            {
                Mode = FileMode.CreateNew,
                Access = FileAccess.ReadWrite,
                Options = FileOptions.DeleteOnClose | FileOptions.Asynchronous,
            });

        if (isOds)
        {
            Export.Ods(spool, columns, headers, page.Rows, name, yes, no, HttpContext.RequestAborted);
        }
        else
        {
            Export.Csv(spool, columns, headers, page.Rows, Locale(culture), yes, no, HttpContext.RequestAborted);
        }

        // Set once the file exists: the error page inherits whatever headers are already on the response.
        Response.ContentType = isOds ? "application/vnd.oasis.opendocument.spreadsheet" : "text/csv; charset=utf-8";
        Response.Headers.ContentDisposition = attachment;
        Response.ContentLength = spool.Length;
        spool.Position = 0;
        await spool.CopyToAsync(Response.Body, HttpContext.RequestAborted).ConfigureAwait(false);
        return new EmptyResult();
    }

    /// <summary>
    /// Stores the columns shown at a level.
    /// </summary>
    /// <param name="level">The level the selection applies to.</param>
    /// <param name="columns">The column keys, in display order.</param>
    /// <response code="200">The selection was stored.</response>
    /// <response code="400">The level is not known.</response>
    /// <returns>The stored selection.</returns>
    [HttpPost("Columns")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public ActionResult<object> SetColumns([FromQuery] string level, [FromBody] IReadOnlyList<string>? columns)
    {
        // Anything stored here is written to the configuration file, which Jellyfin rewrites whole and
        // silently resets if it cannot read it back.
        if (Hierarchy.Level(level) is not { } known)
        {
            return BadRequest($"'{level}' is not a level.");
        }

        var chosen = (columns ?? [])
            .Where(c => Columns.Find(c) is not null)
            .Select(c => Columns.Find(c)!.Key)
            .Distinct(StringComparer.Ordinal)
            .ToArray();

        // An empty selection reads back as the defaults, so storing one would answer with a list
        // the next request does not return.
        if (chosen.Length == 0)
        {
            return BadRequest("No known column was given.");
        }

        var plugin = Plugin.Instance;
        if (plugin is null)
        {
            return Ok(new { Level = known.ToString(), Columns = chosen });
        }

        lock (_configLock)
        {
            var config = plugin.Configuration;
            config.Presets = config.Presets
                .Where(p => p is not null && !string.Equals(p.Level, known.ToString(), StringComparison.OrdinalIgnoreCase))
                .Append(new ColumnPreset { Level = known.ToString(), Columns = chosen })
                .ToArray();

            plugin.UpdateConfiguration(config);
            return Ok(new { Level = known.ToString(), Columns = chosen });
        }
    }

    /// <summary>
    /// Stores how many rows a page holds.
    /// </summary>
    /// <param name="size">The number of rows.</param>
    /// <response code="200">The size was stored.</response>
    /// <response code="400">The size is outside what the table will ask for.</response>
    /// <returns>The stored size.</returns>
    [HttpPost("PageSize")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public ActionResult<object> SetPageSize([FromQuery] int size)
    {
        if (size < 1 || size > PluginConfiguration.MaxPageSize)
        {
            return BadRequest($"A page holds between 1 and {PluginConfiguration.MaxPageSize} rows.");
        }

        var plugin = Plugin.Instance;
        if (plugin is null)
        {
            return Ok(new { PageSize = size });
        }

        lock (_configLock)
        {
            var config = plugin.Configuration;
            config.PageSize = size;
            plugin.UpdateConfiguration(config);
            return Ok(new { PageSize = size });
        }
    }

    /// <summary>
    /// Stores how far a media type is expanded when it opens.
    /// </summary>
    /// <param name="mediaType">The media type.</param>
    /// <param name="level">The deepest level to expand to.</param>
    /// <response code="200">The level was stored.</response>
    /// <response code="400">The level does not belong to that media type.</response>
    /// <returns>The stored level.</returns>
    [HttpPost("Expand")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public ActionResult<object> SetExpandLevel([FromQuery] string mediaType, [FromQuery] string level)
    {
        if (Hierarchy.Resolve(mediaType, level) is not { } known)
        {
            return BadRequest($"'{level}' is not a level of '{mediaType}'.");
        }

        var plugin = Plugin.Instance;
        if (plugin is null)
        {
            return Ok(new { MediaType = mediaType, Level = level });
        }

        var canonical = known.ToString();
        var tab = Hierarchy.Levels(mediaType)![0].ToString();

        lock (_configLock)
        {
            var config = plugin.Configuration;
            config.Expanded = config.Expanded
                .Where(p => p is not null && !string.Equals(p.MediaType, tab, StringComparison.OrdinalIgnoreCase))
                .Append(new ExpandPreference { MediaType = tab, Level = canonical })
                .ToArray();

            plugin.UpdateConfiguration(config);
            return Ok(new { MediaType = tab, Level = canonical });
        }
    }

    // The headers are translated, so the numbers beside them are written the same way round.
    private static CultureInfo Locale(string? culture)
    {
        if (string.IsNullOrWhiteSpace(culture))
        {
            return CultureInfo.InvariantCulture;
        }

        try
        {
            // Anything else is cached forever, so an invented name is a megabyte every few thousand.
            return CultureInfo.GetCultureInfo(culture, predefinedOnly: true);
        }
        catch (CultureNotFoundException)
        {
            return CultureInfo.InvariantCulture;
        }
    }

    private static object Describe(ColumnDefinition column, string? culture) => new
    {
        column.Key,
        Label = Translations.Get(culture, "column." + column.Key),
        Group = Translations.Get(culture, "group." + column.Group),
        GroupKey = column.Group,
        Format = column.Format.ToString()
    };
}
