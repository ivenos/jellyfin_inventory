// Records what the demo needs from a freshly set up server into web/data.json: the schema per
// culture, every row of every level with all columns, and the order the server sorts them in.
// Then asks the server and the demo the same questions and fails where the answers differ.
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { inflateRawSync } from 'node:zlib';
import { createBackend } from './web/backend.js';
import { exportFile } from './web/export.js';

const [base, token] = process.argv.slice(2);
const root = new URL('..', import.meta.url);
const LIMIT = 10000;

function ask(path, params = {}, body) {
    return fetch(`${base}/${path.includes('/') ? path : 'Inventory/' + path}?${new URLSearchParams(params)}`, {
        method: body === undefined ? 'GET' : 'POST',
        headers: { Authorization: `MediaBrowser Token="${token}"`, 'Content-Type': 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
    });
}

async function call(path, params, body) {
    const response = await ask(path, params, body);
    if (!response.ok) { throw new Error(`${response.status} for ${path} ${JSON.stringify(params)}`); }
    const answer = await response.text();
    return answer ? JSON.parse(answer) : null;
}

const settings = `Plugins/${/^guid:\s*"?([0-9a-f-]+)/m.exec(readFileSync(new URL('build.yaml', root), 'utf8'))[1]}/Configuration`;
const fresh = await call(settings);
const server = { Version: (await call('System/Info/Public')).Version.replace(/\.0$/, '') };

const schemas = {};
for (const file of readdirSync(new URL('Jellyfin.Plugin.Inventory/Strings', root)).sort()) {
    const schema = await call('Schema', { culture: file.replace('.json', '') });
    schemas[schema.Culture] = schema;
}

const english = schemas.en;
const keys = english.Columns.map((column) => column.Key);
const other = Object.keys(schemas).find((culture) => culture !== 'en');

const defaults = {};
for (const tab of english.MediaTypes) {
    for (const { Level: level } of tab.Levels) {
        const answer = await call('Items', { mediaType: tab.MediaType, level, limit: 1 });
        defaults[level] = answer.Columns.map((column) => column.Key);
    }
}

for (const level of Object.keys(defaults)) { await call('Columns', { level }, keys); }

const tabs = {};
for (const tab of english.MediaTypes) {
    const mediaType = tab.MediaType;
    const levels = tab.Levels.map((entry) => entry.Level);
    const rows = [];
    const index = new Map();

    for (const level of [...levels].reverse()) {
        const here = await call('Items', { mediaType, level, limit: LIMIT });
        const there = await call('Items', { mediaType, level, limit: LIMIT, culture: other });
        if (here.TotalCount !== here.Rows.length) { throw new Error(`${mediaType}/${level} does not fit one page`); }

        const translated = new Map(there.Rows.map((row) => [row.Id, row.Values]));
        for (const row of here.Rows) {
            if (index.has(row.Id)) { continue; }
            // A cell that reads differently in another language is the word for mixed, not a value.
            const mixed = keys.filter((key) => row.Values[key] !== translated.get(row.Id)[key]);
            index.set(row.Id, rows.length);
            rows.push({
                Id: row.Id,
                ParentId: row.ParentId ?? null,
                Level: level,
                Expandable: row.Expandable,
                Values: Object.fromEntries(keys.filter((key) => !mixed.includes(key) && row.Values[key] != null)
                    .map((key) => [key, row.Values[key]])),
                Mixed: mixed,
            });
        }
    }

    const places = (answer) => answer.Rows.map((row) => index.get(row.Id));
    const top = places(await call('Items', { mediaType, level: levels[0], limit: LIMIT }));

    const natural = {};
    for (const [depth, level] of levels.entries()) {
        if (depth === 0) { continue; }
        const parentIds = rows.filter((row) => row.Level === levels[depth - 1]).map((row) => row.Id).join(',');
        natural[level] = places(await call('Items', { mediaType, level, parentIds }));
    }

    // Only the order is wanted from here on, so the answers need not carry every column.
    await call('Columns', { level: levels[0] }, keys.slice(0, 1));
    const order = {};
    for (const key of keys) {
        order[key] = [];
        for (const descending of [false, true]) {
            // A search for the slash every path holds lists all levels at once.
            const ranked = places(await call('Items', { mediaType, level: levels[0], search: '/', sortBy: key, descending, limit: LIMIT }));
            if (new Set(ranked).size !== rows.length) { throw new Error(`${mediaType} sorted by ${key} misses rows`); }
            order[key].push(ranked);
        }
    }

    tabs[mediaType] = { Levels: levels, Rows: rows, Top: top, Natural: natural, Order: order };
    console.log(`${mediaType}: ${rows.length} rows on ${levels.length} level(s)`);
}

await call(settings, {}, fresh);
const data = { Server: server, Schemas: schemas, Defaults: defaults, Tabs: tabs };
writeFileSync(new URL('demo/web/data.json', root), JSON.stringify(data) + '\n');

const backend = createBackend(data);

function tidy(answer) {
    const clean = (object) => Object.fromEntries(Object.entries(object).filter(([, value]) => value != null));
    return JSON.stringify({
        ...answer,
        Rows: answer.Rows?.map((row) => ({ ...clean(row), Values: clean(row.Values) })),
        Columns: answer.Columns?.map(clean),
        MediaTypes: answer.MediaTypes?.map(clean),
    });
}

function unzip(bytes) {
    const files = {};
    let at = bytes.lastIndexOf(Buffer.from('504b0506', 'hex'));
    const count = bytes.readUInt16LE(at + 10);
    at = bytes.readUInt32LE(at + 16);
    for (let entry = 0; entry < count; entry++) {
        const [name, extra, comment] = [28, 30, 32].map((field) => bytes.readUInt16LE(at + field));
        const local = bytes.readUInt32LE(at + 42);
        const start = local + 30 + bytes.readUInt16LE(local + 26) + bytes.readUInt16LE(local + 28);
        const body = bytes.subarray(start, start + bytes.readUInt32LE(at + 20));
        files[bytes.toString('utf8', at + 46, at + 46 + name)] = (bytes.readUInt16LE(at + 10) ? inflateRawSync(body) : body).toString();
        at += 46 + name + extra + comment;
    }

    return JSON.stringify(files);
}

async function real(path, params) {
    const response = await ask(path, params);
    if (!response.ok) { return 'refused'; }
    if (path !== 'Export') { return tidy(await response.json()); }
    const bytes = Buffer.from(await response.arrayBuffer());
    return params.format === 'ods' ? unzip(bytes) : bytes.toString();
}

async function mine(path, params) {
    try {
        const answer = await backend.request('GET', path, params);
        if (path !== 'Export') { return tidy(JSON.parse(JSON.stringify(answer))); }
        const bytes = Buffer.from(await exportFile(answer).arrayBuffer());
        return params.format === 'ods' ? unzip(bytes) : bytes.toString();
    } catch {
        return 'refused';
    }
}

const questions = [];
const exports = [];
const add = (path, params) => (path === 'Export' ? exports : questions)
    .push([path, Object.fromEntries(Object.entries(params).filter(([, value]) => value !== undefined))]);
const filtered = (...conditions) => JSON.stringify(conditions.map(([column, op, value]) => ({ column, op, value })));

for (const culture of ['en', 'de', 'de-DE', 'fr-CA', 'xx', '']) { add('Schema', { culture }); }

for (const [mediaType, tab] of Object.entries(tabs)) {
    tab.Levels.forEach((name, depth) => {
        const level = name === mediaType ? undefined : name;
        const held = tab.Rows.filter((row) => row.Level === name);
        add('Items', { mediaType, level });
        add('Items', { mediaType, level, culture: 'de' });
        add('Items', { mediaType, level, limit: 5, startIndex: 3 });
        add('Items', { mediaType, level, columnLevel: tab.Levels[0] });

        for (const column of english.Columns) {
            for (const descending of [false, true]) { add('Items', { mediaType, level, sortBy: column.Key, descending }); }

            const seen = [...new Set(held.map((row) => row.Values[column.Key]).filter((value) => value !== undefined))];
            const picks = [seen[0], seen[seen.length >> 1], seen[seen.length - 1]].filter((value) => value !== undefined);
            const values = {
                Text: [...picks, ...picks.map((value) => String(value).slice(1, 4).toUpperCase()), 'zzz', 'a'],
                Boolean: ['true', 'false'],
                Date: [...picks.map((value) => String(value).slice(0, 10)), '2020-01-01', '2030-12-31'],
                Quality: column.Values,
            }[column.Format] ?? [...picks, ...picks.map((value) => value / 3), 0, 1, 1e12];

            for (const op of column.Operators) {
                for (const value of op.endsWith('mpty') ? [undefined] : new Set(values)) {
                    add('Items', { mediaType, level, filters: filtered([column.Key, op, value]) });
                }
            }
        }

        if (depth > 0) {
            const parents = tab.Rows.filter((row) => row.Level === tab.Levels[depth - 1]).map((row) => row.Id);
            for (const ids of [parents, parents.slice(0, 1), parents.slice(1, 3)]) {
                const parentIds = ids.join(',');
                add('Items', { mediaType, level, parentIds, columnLevel: tab.Levels[0] });
                add('Items', { mediaType, level, parentIds, sortBy: 'size', descending: true });
                add('Items', { mediaType, level, parentIds, sortBy: 'name', search: 'e' });
                add('Items', { mediaType, level, parentIds, filters: filtered(['size', 'ge', 1000000]) });
            }
        }

        const name0 = String(held[0]?.Values.name ?? 'none');
        for (const search of ['the', 'THE', 's01', 'mkv', '/media', 'zzz', ' ', name0.slice(0, 6), name0.slice(2, 5), '(20', 'é']) {
            add('Items', { mediaType, level, search });
            add('Items', { mediaType, level, search, sortBy: 'size', descending: true, limit: 4, startIndex: 1 });
            add('Items', { mediaType, level, search, filters: filtered(['size', 'ge', 2000000]) });
        }

        add('Items', { mediaType, level, filters: filtered(['size', 'ge', 1000000], ['name', 'contains', 'a']) });
        add('Items', { mediaType, level, filters: filtered(['videoCodec', 'ne', 'h264'], ['duration', 'le', 3000]) });

        for (const format of ['csv', 'ods']) {
            for (const culture of ['en', 'de']) {
                add('Export', { mediaType, level, format, culture, columnLevel: tab.Levels[0] });
                add('Export', { mediaType, level, format, culture, search: 'the', sortBy: 'size', descending: true });
                add('Export', { mediaType, level, format, culture, filters: filtered(['size', 'ge', 2000000]) });
            }
        }
    });

    for (const wrong of [
        { mediaType: mediaType.toLowerCase() }, { level: 'Nope' }, { sortBy: 'nope' }, { columnLevel: 'Nope' }, { parentIds: 'x' },
        { filters: filtered(['size', 'contains', '1']) }, { filters: filtered(['size', 'ge', 'abc']) },
        { filters: filtered(['name', 'eq', '']) }, { filters: filtered(['dateAdded', 'ge', '2024-02-30']) },
        { filters: filtered(['quality', 'ge', '1080I']) }, { filters: filtered(['interlaced', 'eq', ' TRUE ']) }, { filters: '{' },
    ]) {
        add('Items', { mediaType, ...wrong });
    }

    add('Export', { mediaType, format: 'pdf' });
}

add('Items', { mediaType: 'Nope' });

let differing = 0;
async function compare(asked) {
    for (const [path, params] of asked) {
        const [theirs, ours] = [await real(path, params), await mine(path, params)];
        if (theirs !== ours && differing++ < 10) {
            const at = [...theirs].findIndex((char, position) => char !== ours[position]);
            console.log(`the demo answers ${path} ${JSON.stringify(params)} differently`);
            console.log(`  server: ${theirs.slice(Math.max(0, at - 60), at + 120)}\n  demo:   ${ours.slice(Math.max(0, at - 60), at + 120)}`);
        }
    }
}

await compare(questions);

// With every column, so an export is checked on all the formats a cell can have.
for (const level of Object.keys(defaults)) {
    await call('Columns', { level }, keys);
    await backend.request('POST', 'Columns', { level }, keys);
}

await compare(exports);
await call(settings, {}, fresh);
console.log(`${questions.length + exports.length} answers compared, ${differing} differ`);
process.exit(differing ? 1 : 0);
