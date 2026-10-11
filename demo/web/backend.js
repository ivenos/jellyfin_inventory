// Answers the requests of the configuration page from recorded data, the way InventoryController
// and InventoryService.Query answer them on a server.

const MAX_PAGE_SIZE = 10000;
const SEARCHED = ['name', 'series', 'path'];
const FORMATS = { csv: 'text/csv; charset=utf-8', ods: 'application/vnd.oasis.opendocument.spreadsheet' };
const GUID = /^[0-9a-f]{32}$|^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

class BadRequest extends Error {}

// Ordinal and case-insensitive, as the server compares: one code unit at a time.
function fold(text) {
    return Array.from(String(text).normalize(), (char) => {
        const upper = char.toUpperCase();
        return upper.length === char.length ? upper : char;
    }).join('');
}

function round(number) {
    return Math.round(number * 1000) / 1000;
}

function same(a, b) {
    return String(a).toLowerCase() === String(b).toLowerCase();
}

export function createBackend(data) {
    const cultures = Object.keys(data.Schemas);
    const chosen = { columns: {}, pageSize: null, expanded: {} };
    const levels = Object.values(data.Tabs).flatMap((tab) => tab.Levels);

    const tabs = Object.fromEntries(Object.entries(data.Tabs).map(([type, tab]) => {
        const rows = tab.Rows.map((row, index) => ({ ...row, index }));
        const byId = new Map(rows.map((row) => [row.Id, row]));
        const position = (list) => {
            const at = new Array(rows.length).fill(rows.length);
            list.forEach((index, place) => { at[index] = place; });
            return at;
        };

        return [type, {
            levels: tab.Levels,
            rows,
            byId,
            top: tab.Top.map((index) => rows[index]),
            natural: Object.fromEntries(Object.entries(tab.Natural).map(([level, list]) => [level, position(list)])),
            rank: Object.fromEntries(Object.entries(tab.Order).map(([key, both]) => [key, both.map(position)])),
        }];
    }));

    function resolve(culture) {
        const wanted = String(culture ?? '');
        return cultures.find((known) => same(known, wanted))
            ?? cultures.find((known) => same(known, wanted.split('-')[0]))
            ?? 'en';
    }

    function level(name) {
        return levels.find((known) => same(known, name)) ?? null;
    }

    function column(schema, key) {
        return schema.Columns.find((known) => same(known.Key, key)) ?? null;
    }

    function quality(definition, name) {
        const at = definition.Values.findIndex((known) => same(known, name)
            || (known.endsWith('p') && same(known.slice(0, -1) + 'i', name)));
        return at < 0 ? null : at;
    }

    function readFilter(schema, entry) {
        const text = (property) => {
            const found = entry?.[property];
            return ['string', 'number', 'boolean'].includes(typeof found) ? String(found) : null;
        };
        const definition = column(schema, text('column'));
        if (!definition) { throw new BadRequest(`'${text('column')}' is not a column.`); }

        const op = text('op');
        if (!definition.Operators.includes(op)) {
            throw new BadRequest(`'${op}' is not an operator for '${definition.Key}'.`);
        }

        if (op === 'empty' || op === 'notEmpty') { return { definition, op, value: null }; }

        const raw = text('value');
        let value = null;
        if (raw !== null) {
            if (definition.Format === 'Text') {
                value = raw === '' ? null : fold(raw);
            } else if (definition.Format === 'Boolean') {
                value = /^\s*true\s*$/i.test(raw) ? true : /^\s*false\s*$/i.test(raw) ? false : null;
            } else if (definition.Format === 'Date') {
                const day = /^\d{4}-\d{2}-\d{2}$/.test(raw) ? new Date(raw + 'T00:00:00Z') : null;
                value = day && !Number.isNaN(day.getTime()) && day.toISOString().startsWith(raw) ? raw : null;
            } else if (definition.Format === 'Quality') {
                value = quality(definition, raw);
            } else {
                const number = /^\s*[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?\s*$/i.test(raw) ? Number(raw) : NaN;
                value = Number.isFinite(number) ? number : null;
            }
        }

        if (value === null) { throw new BadRequest(`'${raw}' is not a value for '${definition.Key}'.`); }
        return { definition, op, value };
    }

    function readFilters(schema, json) {
        if (json === undefined || json === null || String(json).trim() === '') { return []; }

        let entries;
        try { entries = JSON.parse(json); } catch { throw new BadRequest('filters is not valid JSON.'); }
        if (!Array.isArray(entries) || entries.length > schema.MaxFilters) {
            throw new BadRequest(`filters has to be a JSON array of at most ${schema.MaxFilters} conditions.`);
        }

        return entries.map((entry) => readFilter(schema, entry));
    }

    function compare(filter, cell) {
        switch (filter.definition.Format) {
            case 'Text': return fold(cell) === filter.value ? 0 : 1;
            case 'Boolean': return typeof cell === 'boolean' ? Number(cell) - Number(filter.value) : -1;
            case 'Date': return String(cell).slice(0, 10).localeCompare(filter.value);
            case 'Quality': {
                const held = quality(filter.definition, cell);
                return held === null ? -1 : held - filter.value;
            }
            default: return round(Number(cell)) - round(filter.value);
        }
    }

    function meets(row, filter) {
        const key = filter.definition.Key;
        if (row.Mixed.includes(key)) { return false; }

        const cell = row.Values[key];
        const blank = cell === null || cell === undefined || cell === '';
        if (filter.op === 'empty' || filter.op === 'notEmpty') { return blank === (filter.op === 'empty'); }
        if (blank) { return filter.op === 'ne' || filter.op === 'notContains'; }

        switch (filter.op) {
            case 'contains': return fold(cell).includes(filter.value);
            case 'notContains': return !fold(cell).includes(filter.value);
            case 'eq': return compare(filter, cell) === 0;
            case 'ne': return compare(filter, cell) !== 0;
            case 'ge': return compare(filter, cell) >= 0;
            default: return compare(filter, cell) <= 0;
        }
    }

    function matches(row, search) {
        return SEARCHED.some((key) => typeof row.Values[key] === 'string' && fold(row.Values[key]).includes(search));
    }

    function covered(tab, row, present) {
        for (let parent = tab.byId.get(row.ParentId); parent; parent = tab.byId.get(parent.ParentId)) {
            if (present.has(parent.Id)) { return true; }
        }

        return false;
    }

    function describe(schema, keys) {
        return keys.map((key) => column(schema, key));
    }

    function selected(schema, selection) {
        return (chosen.columns[selection] ?? data.Defaults[selection]).filter((key) => column(schema, key));
    }

    function schema(params) {
        const answer = structuredClone(data.Schemas[resolve(params.culture)]);
        answer.PageSize = chosen.pageSize ?? answer.PageSize;
        answer.MediaTypes.forEach((type) => {
            if (type.MediaType in chosen.expanded) { type.ExpandedTo = chosen.expanded[type.MediaType]; }
        });
        return answer;
    }

    function shown(known, keys, row) {
        return {
            Id: row.Id,
            ParentId: row.ParentId,
            Expandable: row.Expandable,
            Values: Object.fromEntries(keys.map((key) => [
                key, row.Mixed.includes(key) ? known.Strings.Mixed : row.Values[key]])),
        };
    }

    function list(params, topmost) {
        const known = data.Schemas[resolve(params.culture)];
        const type = Object.keys(tabs).find((name) => same(name, params.mediaType));
        const tab = tabs[type];
        const kind = tab && (params.level ? tab.levels.find((name) => same(name, params.level)) : tab.levels[0]);
        if (!kind) { throw new BadRequest(`Unknown media type '${params.mediaType}' or level '${params.level}'.`); }

        const selection = level(params.columnLevel || params.level || type);
        if (!selection) { throw new BadRequest(`'${params.columnLevel}' is not a level.`); }

        const sortBy = params.sortBy ? column(known, params.sortBy)?.Key : null;
        if (params.sortBy && !sortBy) { throw new BadRequest(`'${params.sortBy}' is not a column.`); }

        const filters = readFilters(known, params.filters);
        const keys = selected(known, selection);
        const parents = params.parentIds === undefined || params.parentIds === null
            ? null
            : new Set(String(params.parentIds).split(',').map((id) => id.trim()).filter(Boolean));
        if (parents && (parents.size === 0 || [...parents].some((id) => !GUID.test(id)))) {
            throw new BadRequest('parentIds has to be a comma separated list of item ids.');
        }

        const search = String(params.search ?? '').normalize();
        const searching = search.trim() !== '';
        const needle = fold(search);
        const spanning = searching && !parents && kind === tab.levels[0];

        let rows;
        if (spanning) {
            rows = tab.rows.filter((row) => matches(row, needle) && filters.every((filter) => meets(row, filter)));
        } else {
            if (parents) {
                rows = tab.rows.filter((row) => row.Level === kind && parents.has(row.ParentId));
            } else {
                rows = kind === tab.levels[0] ? tab.top : tab.rows.filter((row) => row.Level === kind);
            }

            if (searching) { rows = rows.filter((row) => matches(row, needle)); }
            rows = rows.filter((row) => filters.every((filter) => meets(row, filter)));
        }

        let counted = rows;
        if (spanning && rows.length > 1) {
            const present = new Set(rows.map((row) => row.Id));
            counted = rows.filter((row) => !covered(tab, row, present));
        }

        if (topmost) { rows = counted; }

        const sortKey = sortBy ?? (parents ? null : keys[0]);
        const place = sortKey
            ? tab.rank[sortKey][String(params.descending) === 'true' ? 1 : 0]
            : tab.natural[kind];
        const sorted = place ? [...rows].sort((a, b) => place[a.index] - place[b.index]) : rows;

        return { known, kind, keys, parents, rows, counted, sorted };
    }

    function items(params) {
        const { known, keys, parents, rows, counted, sorted } = list(params, false);
        const start = parents ? 0 : Math.max(0, Number(params.startIndex) || 0);
        const size = Number(params.limit) || chosen.pageSize || known.PageSize;
        const limit = parents ? sorted.length : Math.min(Math.max(size, 1), MAX_PAGE_SIZE);

        return {
            Rows: sorted.slice(start, start + limit).map((row) => shown(known, keys, row)),
            TotalCount: rows.length,
            TotalSize: counted.reduce((sum, row) => sum + (row.Values.size ?? 0), 0),
            TotalDuration: round(counted.reduce((sum, row) => sum + (row.Values.duration ?? 0), 0)),
            Columns: describe(known, keys),
        };
    }

    function exported(params) {
        const format = Object.keys(FORMATS).find((name) => same(name, params.format));
        if (!format) { throw new BadRequest(`Unknown format '${params.format}'.`); }

        const { known, kind, keys, sorted } = list({ ...params, parentIds: undefined }, true);
        return {
            Format: format,
            FileName: `inventory-${kind.toLowerCase()}.${format}`,
            ContentType: FORMATS[format],
            Culture: params.culture,
            SheetName: known.Strings[`level.${kind}`],
            Yes: known.Strings.Yes,
            No: known.Strings.No,
            Columns: describe(known, keys),
            Rows: sorted.map((row) => shown(known, keys, row)),
        };
    }

    function setColumns(params, body) {
        const known = data.Schemas.en;
        const selection = level(params.level);
        if (!selection) { throw new BadRequest(`'${params.level}' is not a level.`); }

        const keys = [...new Set((Array.isArray(body) ? body : [])
            .map((key) => column(known, key)?.Key).filter(Boolean))];
        if (keys.length === 0) { throw new BadRequest('No known column was given.'); }

        chosen.columns[selection] = keys;
        return { Level: selection, Columns: keys };
    }

    function setPageSize(params) {
        const size = Number(params.size);
        if (!Number.isInteger(size) || size < 1 || size > MAX_PAGE_SIZE) {
            throw new BadRequest(`A page holds between 1 and ${MAX_PAGE_SIZE} rows.`);
        }

        chosen.pageSize = size;
        return { PageSize: size };
    }

    function setExpand(params) {
        const type = Object.keys(tabs).find((name) => same(name, params.mediaType));
        const kind = type && tabs[type].levels.find((name) => same(name, params.level));
        if (!kind) { throw new BadRequest(`'${params.level}' is not a level of '${params.mediaType}'.`); }

        chosen.expanded[type] = kind;
        return { MediaType: type, Level: kind };
    }

    const routes = {
        'GET Schema': schema,
        'GET Items': items,
        'GET Export': exported,
        'POST Columns': setColumns,
        'POST PageSize': setPageSize,
        'POST Expand': setExpand,
    };

    return {
        // Rejects where the server would answer 400, so the page takes the same path.
        request(method, path, params, body) {
            const route = routes[`${method} ${path}`];
            try {
                if (!route) { throw new BadRequest(`${method} ${path} is not part of the demo.`); }
                return Promise.resolve(route(params ?? {}, body));
            } catch (error) {
                return Promise.reject(error);
            }
        },
    };
}
