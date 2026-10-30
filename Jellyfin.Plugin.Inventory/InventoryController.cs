using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Data.Enums;
using Jellyfin.Database.Implementations.Entities;
using Jellyfin.Plugin.Inventory.Configuration;
using MediaBrowser.Common.Api;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Collections;
using MediaBrowser.Controller.Dto;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Controller.Entities.Movies;
using MediaBrowser.Controller.Library;
using MediaBrowser.Controller.Playlists;
using MediaBrowser.Model.IO;
using MediaBrowser.Model.Playlists;
using MediaBrowser.Model.Tasks;
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

    private static readonly SemaphoreSlim _targetLock = new(1, 1);

    // Any other name is cached for good, and a private-use one like "x-a" has no number format.
    private static readonly HashSet<string> _cultures = CultureInfo.GetCultures(CultureTypes.AllCultures)
        .Select(c => c.Name)
        .Where(n => n.Length > 0)
        .ToHashSet(StringComparer.OrdinalIgnoreCase);

    private readonly InventoryService _inventory;
    private readonly IUserManager _userManager;
    private readonly IApplicationPaths _paths;
    private readonly ILibraryManager _libraryManager;
    private readonly ICollectionManager _collectionManager;
    private readonly IPlaylistManager _playlistManager;
    private readonly IFileSystem _fileSystem;
    private readonly ITaskManager _taskManager;

    /// <summary>
    /// Initializes a new instance of the <see cref="InventoryController"/> class.
    /// </summary>
    /// <param name="inventory">Instance of the <see cref="InventoryService"/>.</param>
    /// <param name="userManager">Instance of the <see cref="IUserManager"/> interface.</param>
    /// <param name="paths">Instance of the <see cref="IApplicationPaths"/> interface.</param>
    /// <param name="libraryManager">Instance of the <see cref="ILibraryManager"/> interface.</param>
    /// <param name="collectionManager">Instance of the <see cref="ICollectionManager"/> interface.</param>
    /// <param name="playlistManager">Instance of the <see cref="IPlaylistManager"/> interface.</param>
    /// <param name="fileSystem">Instance of the <see cref="IFileSystem"/> interface.</param>
    /// <param name="taskManager">Instance of the <see cref="ITaskManager"/> interface.</param>
    public InventoryController(
        InventoryService inventory,
        IUserManager userManager,
        IApplicationPaths paths,
        ILibraryManager libraryManager,
        ICollectionManager collectionManager,
        IPlaylistManager playlistManager,
        IFileSystem fileSystem,
        ITaskManager taskManager)
    {
        _inventory = inventory;
        _userManager = userManager;
        _paths = paths;
        _libraryManager = libraryManager;
        _collectionManager = collectionManager;
        _playlistManager = playlistManager;
        _fileSystem = fileSystem;
        _taskManager = taskManager;
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
    private User? Reader(IReadOnlyList<ColumnDefinition> columns, string? sortBy, IReadOnlyList<RowFilter> filters)
        => Uses(columns, sortBy, filters, ColumnSource.User) ? Caller : null;

    private static bool Uses(
        IReadOnlyList<ColumnDefinition> columns,
        string? sortBy,
        IReadOnlyList<RowFilter> filters,
        ColumnSource source)
        => columns.Any(c => c.Source == source)
            || Columns.Find(sortBy)?.Source == source
            || filters.Any(f => f.Column.Source == source);

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
                ExpandedTo = config.GetExpandLevel(t.MediaType),
                t.Targets
            }),
            Columns = Columns.All.Select(c => Describe(c, culture)),
            PageSize = Math.Clamp(config.PageSize, 1, PluginConfiguration.MaxPageSize),
            MaxFilters = RowFilter.MaxCount,
            Culture = Translations.Resolve(culture),
            Strings = Translations.All(culture)
        });
    }

    /// <summary>
    /// Gets one page of rows.
    /// </summary>
    /// <param name="mediaType">The media type to list.</param>
    /// <param name="level">The level within it, or empty for the one the tab is named after.</param>
    /// <param name="parentIds">Comma separated ids; when given, only the children of those rows are
    /// returned, and the whole set comes back unpaged since it belongs to rows already on screen.</param>
    /// <param name="columnLevel">The level whose column selection to use, for children shown inside
    /// their parent's table. Defaults to the level being listed.</param>
    /// <param name="culture">The culture to translate the column headers into.</param>
    /// <param name="search">An optional substring the name, series, path or a person must contain.</param>
    /// <param name="filters">Conditions every row has to meet, as a JSON array of objects with
    /// "column", "op" and "value".</param>
    /// <param name="sortBy">The column to sort on.</param>
    /// <param name="descending">Whether to sort descending.</param>
    /// <param name="startIndex">The first row to return.</param>
    /// <param name="limit">How many rows to return.</param>
    /// <response code="200">The requested page.</response>
    /// <response code="400">The media type, level, column level or sort column is not known, or a
    /// filter cannot be read.</response>
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
        [FromQuery] string? filters,
        [FromQuery] string? sortBy,
        [FromQuery] bool descending = false,
        [FromQuery] int startIndex = 0,
        [FromQuery] int? limit = null)
    {
        var config = Configuration;
        if (Hierarchy.Resolve(mediaType, level) is not { } listed)
        {
            return BadRequest($"Unknown media type '{mediaType}' or level '{level}'.");
        }

        var selection = string.IsNullOrEmpty(columnLevel) ? listed.ToString() : columnLevel;

        if (Hierarchy.Level(selection) is null)
        {
            return BadRequest($"'{columnLevel}' is not a level.");
        }

        if (!string.IsNullOrEmpty(sortBy) && Columns.Find(sortBy) is null)
        {
            return BadRequest($"'{sortBy}' is not a column.");
        }

        var conditions = RowFilter.Parse(filters, out var unreadable);
        if (unreadable is not null)
        {
            return BadRequest(unreadable);
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
            Reader(columns, sortBy, conditions),
            Uses(columns, sortBy, conditions, ColumnSource.Everyone),
            columns,
            search,
            conditions,
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
    /// <param name="level">The level to export, or empty for the one the tab is named after.</param>
    /// <param name="columnLevel">The level whose column selection to use. Defaults to the level
    /// being exported.</param>
    /// <param name="format">Either "csv" or "ods".</param>
    /// <param name="culture">The culture the headers appear in.</param>
    /// <param name="search">An optional substring to filter on.</param>
    /// <param name="filters">Conditions every row has to meet, as <c>Items</c> takes them.</param>
    /// <param name="sortBy">The column that decides the row order.</param>
    /// <param name="descending">Whether that order is reversed.</param>
    /// <response code="200">The spreadsheet.</response>
    /// <response code="400">The media type, level, column level, format or sort column is not
    /// known, or a filter cannot be read.</response>
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
        [FromQuery] string? filters,
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

        var conditions = RowFilter.Parse(filters, out var unreadable);
        if (unreadable is not null)
        {
            return BadRequest(unreadable);
        }

        var columns = Columns.Resolve(Configuration.GetColumns(selection), selection);
        var headers = columns.Select(c => Translations.Get(culture, "column." + c.Key)).ToArray();

        var page = _inventory.Query(
            mediaType,
            level,
            null,
            Reader(columns, sortBy, conditions),
            Uses(columns, sortBy, conditions, ColumnSource.Everyone),
            columns,
            search,
            conditions,
            sortBy,
            descending,
            0,
            int.MaxValue,
            culture,
            topmost: true);
        var name = Translations.Get(culture, "level." + exported);
        var yes = Translations.Get(culture, "Yes");
        var no = Translations.Get(culture, "No");
        var attachment = $"attachment; filename=inventory-{FileName(kind.Value)}.{(isOds ? "ods" : "csv")}";

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

        try
        {
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
        }
        catch (OperationCanceledException) when (HttpContext.RequestAborted.IsCancellationRequested)
        {
        }

        return new EmptyResult();
    }

    /// <summary>
    /// Stores the columns shown at a level. Books that show what their files were given keep that once the files change.
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
            var presets = config.Presets
                .Where(p => p is not null && !string.Equals(p.Level, known.ToString(), StringComparison.OrdinalIgnoreCase));

            var books = nameof(BaseItemKind.Folder);
            if (known == BaseItemKind.AudioBook && !config.Presets.Any(p => string.Equals(p?.Level, books, StringComparison.OrdinalIgnoreCase)))
            {
                presets = presets.Append(new ColumnPreset { Level = books, Columns = config.GetColumns(books) ?? [] });
            }

            config.Presets = presets.Append(new ColumnPreset { Level = known.ToString(), Columns = chosen }).ToArray();

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
        var tab = Hierarchy.Tab(Hierarchy.Levels(mediaType)!).ToString();

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

    /// <summary>
    /// Gets what items can be added to: every collection, and the playlists the caller owns or may edit.
    /// </summary>
    /// <response code="200">The targets, each sorted by name.</response>
    /// <returns>The collections, and the playlists, which an API key has none of.</returns>
    [HttpGet("Targets")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public ActionResult<object> GetTargets()
    {
        var user = Caller;
        return Ok(new
        {
            Collections = _inventory.Collections().Select(c => new { c.Id, c.Name }),
            Playlists = user is null ? null : _inventory.Playlists(user).Select(p => new { p.Id, p.Name })
        });
    }

    /// <summary>
    /// Adds items to a collection or a playlist, or takes them out of one. A playlist takes what a
    /// folder plays rather than the folder, and nothing it already holds a second time.
    /// </summary>
    /// <param name="request">The target and the items.</param>
    /// <response code="200">The target, how many entries it gained or lost, and how many of the items
    /// cannot go there.</response>
    /// <response code="400">The kind is not known, the request names both an existing target and a new
    /// one or neither, the name is empty or too long for a folder, the playlist is not the caller's to edit,
    /// the listing cannot be read, no item was given, or a playlist was asked for without a user.</response>
    /// <response code="404">The target does not exist.</response>
    /// <returns>The outcome.</returns>
    [HttpPost("Targets")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<object>> SetTargets([FromBody] TargetRequest? request)
    {
        var playlist = string.Equals(request?.Kind, Hierarchy.Playlist, StringComparison.OrdinalIgnoreCase);
        if (request is null || (!playlist && !string.Equals(request.Kind, Hierarchy.Collection, StringComparison.OrdinalIgnoreCase)))
        {
            return BadRequest($"Unknown kind '{request?.Kind}'.");
        }

        var name = request.Name?.Trim();
        if ((request.Id is null) == (name is null) || (request.Remove && name is not null))
        {
            return BadRequest("Give either the id of a target or, when adding, the name of a new one.");
        }

        if (name is { Length: 0 })
        {
            return BadRequest("A new target needs a name.");
        }

        var user = Caller;
        if (playlist && user is null)
        {
            return BadRequest("A playlist belongs to a user, and an API key is nobody.");
        }

        var target = request.Id is { } id && !id.Equals(default) ? _libraryManager.GetItemById(id) as Folder : null;
        if (request.Id is not null && (playlist ? target is not Playlist : target is not BoxSet))
        {
            return NotFound($"No {request.Kind} has the id {request.Id}.");
        }

        if (playlist && target is not null && !_inventory.Playlists(user!).Any(p => p.Id.Equals(target.Id)))
        {
            return BadRequest("The playlist is not one the caller may edit.");
        }

        HashSet<Guid> except = [.. request.All?.Except ?? []];
        var items = Pick(request, except, out var asked, out var wrong);
        if (wrong is not null)
        {
            return BadRequest(wrong);
        }

        await _targetLock.WaitAsync().ConfigureAwait(false);
        try
        {
            return playlist
                ? await SetPlaylist(request.Remove, target as Playlist, name, user!, items, asked, except).ConfigureAwait(false)
                : await SetCollection(request.Remove, target as BoxSet, name, items, asked).ConfigureAwait(false);
        }
        catch (PathTooLongException)
        {
            return BadRequest("The name is too long for a folder.");
        }
        finally
        {
            _targetLock.Release();
        }
    }

    /// <summary>
    /// Gets the targets that hold any of the items: the collections they are in, and the caller's
    /// playlists that hold what they play.
    /// </summary>
    /// <param name="request">The items, in <c>Ids</c> and <c>All</c> as <c>POST Targets</c> takes them.</param>
    /// <response code="200">The targets, each sorted by name.</response>
    /// <response code="400">The listing cannot be read, or no item was given.</response>
    /// <returns>The collections, and the playlists, which an API key has none of.</returns>
    [HttpPost("Targets/Held")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public ActionResult<object> GetHeld([FromBody] TargetRequest? request)
    {
        if (request is null)
        {
            return BadRequest("No item was given.");
        }

        HashSet<Guid> except = [.. request.All?.Except ?? []];
        var items = Pick(request, except, out _, out var wrong);
        if (wrong is not null)
        {
            return BadRequest(wrong);
        }

        var user = Caller;
        var ids = items.Select(i => i.Id).ToHashSet();
        var played = user is null ? [] : items.SelectMany(i => Playable(i, user, except)).Select(i => i.Id).ToHashSet();
        return Ok(new
        {
            Collections = _inventory.Collections().Where(c => Linked(c).Any(ids.Contains)).Select(c => new { c.Id, c.Name }),
            Playlists = user is null ? null : _inventory.Playlists(user).Where(p => Linked(p).Any(played.Contains)).Select(p => new { p.Id, p.Name })
        });
    }

    private BaseItem[] Pick(TargetRequest request, IReadOnlySet<Guid> except, out int asked, out string? error)
    {
        asked = 0;
        error = null;
        var ids = new List<Guid>(request.Ids ?? []);
        if (request.All is { } all)
        {
            if (Hierarchy.Resolve(all.MediaType ?? string.Empty, all.Level) is null)
            {
                error = $"Unknown media type '{all.MediaType}' or level '{all.Level}'.";
                return [];
            }

            var conditions = RowFilter.Parse(all.Filters, out error);
            if (error is not null)
            {
                return [];
            }

            IReadOnlyList<ColumnDefinition> columns = [Columns.Find("name")!];
            var listed = _inventory.Query(
                all.MediaType!,
                all.Level,
                null,
                Reader(columns, null, conditions),
                Uses(columns, null, conditions, ColumnSource.Everyone),
                columns,
                all.Search,
                conditions,
                null,
                false,
                0,
                int.MaxValue,
                topmost: true,
                except: except);
            ids.AddRange(listed.Rows.Select(r => r.Id));
        }

        var wanted = ids.Distinct().ToArray();
        asked = wanted.Length;
        if (wanted.Length == 0)
        {
            error = "No item was given.";
            return [];
        }

        var known = _libraryManager.GetItemList(new InternalItemsQuery { ItemIds = wanted, DtoOptions = new DtoOptions(false) })
            .ToDictionary(i => i.Id);
        return wanted.Select(known.GetValueOrDefault).OfType<BaseItem>()
            .Where(i => Hierarchy.Of(i.GetBaseItemKind()) is not null)
            .ToArray();
    }

    private static BaseItem[] Playable(BaseItem item, User user, IReadOnlySet<Guid> except)
        => Playlist.GetPlaylistItems([item], user, new DtoOptions(false)).Where(i => i.SupportsAddingToPlaylist && !except.Contains(i.Id)).ToArray();

    private static Guid[] Linked(Folder target) => target.LinkedChildren.Select(c => c.ItemId).OfType<Guid>().ToArray();

    private async Task<ActionResult<object>> SetCollection(bool remove, BoxSet? target, string? name, BaseItem[] items, int asked)
    {
        var holdable = items
            .Where(i => Hierarchy.Targets(i.GetBaseItemKind()).Contains(Hierarchy.Collection))
            .Select(i => i.Id)
            .ToArray();

        // Jellyfin keeps a collection in a folder named after it, and a second one that makes the same folder replaces the first.
        var folder = name is null ? null : _fileSystem.GetValidFilename(name) + " [boxset]";
        target ??= _inventory.Collections().FirstOrDefault(c => string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase)
            || string.Equals(Path.GetFileName(c.Path), folder, StringComparison.OrdinalIgnoreCase));
        if (target is null)
        {
            // In 12.0 the scan that follows adding the Collections library saves over a collection made meanwhile, emptying it.
            if (typeof(ICollectionManager).Assembly.GetName().Version is { Major: 12, Minor: 0 }
                && await _collectionManager.GetCollectionsFolder(false).ConfigureAwait(false) is null)
            {
                await AddCollectionsLibrary().ConfigureAwait(false);
            }

            var created = await _collectionManager.CreateCollectionAsync(new CollectionCreationOptions
            {
                Name = name,
                ItemIdList = holdable.Select(i => i.ToString("N", CultureInfo.InvariantCulture)).ToArray()
            }).ConfigureAwait(false);
            return Ok(Outcome(created.Id, created.Name, holdable.Length, asked - holdable.Length));
        }

        var linked = Linked(target).ToHashSet();
        var moved = holdable.Where(i => remove ? linked.Contains(i) : !linked.Contains(i)).ToArray();
        if (moved.Length > 0)
        {
            await (remove
                ? _collectionManager.RemoveFromCollectionAsync(target.Id, moved)
                : _collectionManager.AddToCollectionAsync(target.Id, moved)).ConfigureAwait(false);
        }

        return Ok(Outcome(target.Id, target.Name, moved.Length, asked - holdable.Length));
    }

    private async Task AddCollectionsLibrary()
    {
        var scanned = new TaskCompletionSource();
        void OnCompleted(object? sender, TaskCompletionEventArgs e)
        {
            if (e.Task.ScheduledTask.Key == "RefreshLibrary" && e.Result.Status != TaskCompletionStatus.Cancelled)
            {
                scanned.TrySetResult();
            }
        }

        _taskManager.TaskCompleted += OnCompleted;
        try
        {
            await _collectionManager.GetCollectionsFolder(true).ConfigureAwait(false);
            await scanned.Task.WaitAsync(TimeSpan.FromMinutes(10)).ConfigureAwait(false);
        }
        finally
        {
            _taskManager.TaskCompleted -= OnCompleted;
        }
    }

    private async Task<ActionResult<object>> SetPlaylist(bool remove, Playlist? target, string? name, User user, BaseItem[] items, int asked, IReadOnlySet<Guid> except)
    {
        // Expanded here rather than by Jellyfin, which adds what the playlist already holds a second time.
        var entries = new List<Guid>();
        var skipped = asked - items.Length;
        foreach (var item in items)
        {
            var playable = Playable(item, user, except);
            skipped += playable.Length == 0 ? 1 : 0;
            entries.AddRange(playable.Select(i => i.Id));
        }

        var linked = target is null ? [] : Linked(target);
        if (remove)
        {
            var gone = entries.ToHashSet();
            var removed = linked.Count(gone.Contains);
            if (removed > 0)
            {
                await _playlistManager.RemoveItemFromPlaylistAsync(
                    target!.Id.ToString("N", CultureInfo.InvariantCulture),
                    gone.Where(linked.Contains).Select(i => i.ToString("N", CultureInfo.InvariantCulture)).ToArray()).ConfigureAwait(false);
            }

            return Ok(Outcome(target!.Id, target.Name, removed, skipped));
        }

        var held = linked.ToHashSet();
        var fresh = entries.Distinct().Where(i => !held.Contains(i)).ToArray();
        if (target is null)
        {
            var created = await _playlistManager.CreatePlaylist(new PlaylistCreationRequest
            {
                Name = name,
                ItemIdList = fresh,
                UserId = user.Id
            }).ConfigureAwait(false);
            return Ok(Outcome(Guid.Parse(created.Id), name, fresh.Length, skipped));
        }

        if (fresh.Length > 0)
        {
            await _playlistManager.AddItemToPlaylistAsync(target.Id, fresh, null, user.Id).ConfigureAwait(false);
        }

        return Ok(Outcome(target.Id, target.Name, fresh.Length, skipped));
    }

    private static object Outcome(Guid id, string? name, int count, int skipped)
        => new { Id = id, Name = name, Count = count, Skipped = skipped };

    private static string FileName(BaseItemKind kind) => kind switch
    {
        BaseItemKind.Folder => "audiobook",
        BaseItemKind.AudioBook => "audiobook-files",
        _ => kind.ToString().ToLowerInvariant()
    };

    // The headers are translated, so the numbers beside them are written the same way round.
    private static CultureInfo Locale(string? culture)
        => culture is not null && _cultures.Contains(culture) ? CultureInfo.GetCultureInfo(culture) : CultureInfo.InvariantCulture;

    private static object Describe(ColumnDefinition column, string? culture) => new
    {
        column.Key,
        Label = Translations.Get(culture, "column." + column.Key),
        Group = Translations.Get(culture, "group." + column.Group),
        GroupKey = column.Group,
        Format = column.Format.ToString(),
        column.List,
        Operators = RowFilter.Operators(column.Format),
        Values = column.Format == ColumnFormat.Quality ? VideoQuality.Names : null
    };
}
