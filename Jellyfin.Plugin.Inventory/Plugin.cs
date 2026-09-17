using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Jellyfin.Plugin.Inventory.Configuration;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Common.Plugins;
using MediaBrowser.Model.Plugins;
using MediaBrowser.Model.Serialization;
using Microsoft.AspNetCore.Http;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// The Inventory plugin.
/// </summary>
public class Plugin : BasePlugin<PluginConfiguration>, IHasWebPages
{
    private readonly IHttpContextAccessor _requests;

    /// <summary>
    /// Initializes a new instance of the <see cref="Plugin"/> class.
    /// </summary>
    /// <param name="applicationPaths">Instance of the <see cref="IApplicationPaths"/> interface.</param>
    /// <param name="xmlSerializer">Instance of the <see cref="IXmlSerializer"/> interface.</param>
    /// <param name="requests">Instance of the <see cref="IHttpContextAccessor"/> interface.</param>
    public Plugin(IApplicationPaths applicationPaths, IXmlSerializer xmlSerializer, IHttpContextAccessor requests)
        : base(applicationPaths, xmlSerializer)
    {
        _requests = requests;
        Instance = this;
    }

    /// <summary>
    /// Gets the current plugin instance.
    /// </summary>
    public static Plugin? Instance { get; private set; }

    /// <inheritdoc />
    public override string Name => "Inventory";

    /// <inheritdoc />
    public override string Description => "A sortable, filterable table of everything in your libraries.";

    /// <inheritdoc />
    public override Guid Id => Guid.Parse("ed020473-559f-42c1-850f-53349b29d838");

    /// <inheritdoc />
    public IEnumerable<PluginPageInfo> GetPages()
    {
        return
        [
            new PluginPageInfo
            {
                Name = Name,
                DisplayName = Translations.Get(Language(), "Title"),
                EmbeddedResourcePath = string.Format(CultureInfo.InvariantCulture, "{0}.Configuration.configPage.html", GetType().Namespace),
                EnableInMainMenu = true,
                MenuIcon = "table_chart"
            }
        ];
    }

    // The language a user picks in the web client stays in their browser, so the entry in the
    // dashboard menu follows the one their browser asks in.
    private string? Language()
        => _requests.HttpContext?.Request.GetTypedHeaders().AcceptLanguage
            .OrderByDescending(language => language.Quality ?? 1)
            .Select(language => language.Value.Value)
            .FirstOrDefault(tag => !string.Equals(Translations.Resolve(tag), Translations.FallbackCulture, StringComparison.Ordinal));
}
