import { readFileSync } from 'node:fs';
import { JSDOM, VirtualConsole } from 'jsdom';

const [html, schemaFile, ...itemFiles] = process.argv.slice(2);
const schema = JSON.parse(readFileSync(schemaFile, 'utf8'));
const source = readFileSync(html, 'utf8');
const read = (file) => JSON.parse(readFileSync(file, 'utf8'));
const raised = [];

function gate() {
    let open;
    const held = new Promise((resolve) => { open = resolve; });
    return { held: held, open: open };
}

async function render(items, mode) {
    let overlay = 0;
    let served = 0;
    let downloads = 0;
    let failing = false;
    const schemaGates = [gate(), gate()];
    const held = gate();
    const rows = gate();
    // A tab with a level under it, so its rows carry a control that opens them.
    const openable = JSON.parse(JSON.stringify(items));
    openable.Rows.forEach(function (row) { row.Expandable = true; });
    const deep = JSON.parse(JSON.stringify(schema));
    deep.MediaTypes[0].Levels.push({ Level: 'Child', Label: 'Children' });
    deep.MediaTypes[0].ExpandedTo = null;
    const download = gate();
    const asked = [];
    // The second visit finds a library that has changed, so a discarded answer is visible.
    const changed = JSON.parse(JSON.stringify(schema));
    changed.MediaTypes.forEach(function (type) { type.Label = 'New ' + type.Label; });

    const dom = new JSDOM(source, {
        runScripts: 'dangerously',
        url: 'http://localhost/web/index.html',
        virtualConsole: new VirtualConsole()
            .on('jsdomError', (e) => { if (e.type !== 'not implemented') { raised.push(e.message); } }),
        beforeParse(window) {
            window.ApiClient = {
                serverId: () => 'server',
                accessToken: () => 'token',
                getUrl: (path, params) => path + '?' + new window.URLSearchParams(params || {}),
                getJSON: (url) => {
                    asked.push(url);
                    if (url.startsWith('Inventory/Schema')) {
                        if (mode === 'stuck') { return Promise.resolve(deep); }
                        const call = ++served;
                        if (mode === 'stale') {
                            return call > 1 ? schemaGates[1].held.then(() => changed) : Promise.resolve(schema);
                        }
                        if (mode === 'overlay') {
                            return schemaGates[call - 1].held.then(() => (call > 1 ? changed : schema));
                        }
                        return Promise.resolve(schema);
                    }

                    if (url.startsWith('Inventory/Items')) {
                        if (mode === 'failed' || failing) { return Promise.reject(new Error('no')); }
                        if (mode === 'stuck' && url.includes('parentIds=')) {
                            return held.held.then(() => items);
                        }

                        if (mode === 'stuck') { return Promise.resolve(openable); }
                        // Held so the busy state can be read while the rows are still on their way.
                        return mode === 'stale' || mode === 'overlay'
                            ? Promise.resolve(items)
                            : rows.held.then(() => items);
                    }

                    return Promise.reject(new Error('unexpected ' + url));
                },
                ajax: () => Promise.resolve({}),
            };
            window.Dashboard = {
                showLoadingMsg() { overlay++; },
                hideLoadingMsg() { overlay = 0; },
                alert(message) {
                    if (!['failed', 'retry', 'stuck', 'switch'].includes(mode)) {
                        throw new Error('the page gave up: ' + message);
                    }
                },
            };
            window.URL.createObjectURL = () => 'blob:export';
            window.URL.revokeObjectURL = () => {};
            // The first export of a hung run never lands, the way a half open connection behaves.
            window.fetch = () => (mode === 'hung' && ++downloads === 1
                ? new Promise(() => {})
                : download.held.then(() => ({ ok: true, blob: () => Promise.resolve('bytes') })));
        },
    });

    const { window } = dom;
    const page = window.document.querySelector('#InventoryPage');
    const settle = async () => {
        for (let i = 0; i < 20; i++) { await new Promise((done) => window.setTimeout(done, 0)); }
    };
    const spinning = () => page.querySelectorAll('.invType.invLoad, .invBusy').length;
    const show = () => page.dispatchEvent(new window.Event('pageshow'));
    const leave = () => page.dispatchEvent(new window.Event('viewhide'));
    const click = (selector) => page.querySelector(selector)
        .dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
    const all = (selector) => [...page.querySelectorAll(selector)].map((n) => n.textContent.trim());
    const buttons = () => [page.querySelector('#invCsv'), page.querySelector('#invOds')];
    const disabled = () => buttons().map((b) => b.disabled).join(',');

    show();
    await settle();
    const waiting = spinning();

    if (mode === 'stale') {
        show();
        await settle();
        // A tab is clickable while the schema of this visit is still on its way.
        page.querySelectorAll('.invType')[1].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
        await settle();
        schemaGates[1].open();
        await settle();
        const report = { overlay: overlay, tabs: all('.invType').join(',') };
        window.close();
        return report;
    }

    if (mode === 'overlay') {
        leave();
        await settle();
        show();
        await settle();
        // The answer to the visit that was left arrives while this one is still waiting.
        schemaGates[0].open();
        await settle();
        const stolen = overlay;
        schemaGates[1].open();
        await settle();
        const report = { pending: stolen, settled: overlay, tabs: all('.invType').join(',') };
        window.close();
        return report;
    }

    if (mode === 'hide') {
        // Left while the rows are still on their way, which is when a spinner gets stranded.
        leave();
        await settle();
        const stranded = spinning();
        rows.open();
        await settle();
        window.close();
        return { busy: waiting, stranded: stranded };
    }

    rows.open();
    await settle();

    if (mode === 'failed') {
        const report = {
            message: page.querySelector('#invEmpty').textContent.trim(),
            shown: page.querySelector('#invEmpty').style.display !== 'none',
            columns: page.querySelector('#invColumnsBtn').disabled,
        };
        window.close();
        return report;
    }

    if (mode === 'hung') {
        click('#invCsv');
        await settle();
        const during = disabled();
        // Left with the download still open, then asked for the other format on the way back.
        leave();
        await settle();
        show();
        await settle();
        click('#invOds');
        await settle();
        download.open();
        await settle();
        const report = { during: during, after: disabled(), spinning: spinning() };
        window.close();
        return report;
    }

    if (mode === 'retry') {
        failing = true;
        click('#invNext');
        await settle();
        const stale = page.querySelector('#invPage').textContent.trim();
        failing = false;
        click('#invNext');
        await settle();
        const items = () => asked.filter((url) => url.startsWith('Inventory/Items'));
        const turned = items().pop().match(/startIndex=\d+/)[0];
        failing = true;
        page.querySelector('#invHead th').dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
        await settle();
        failing = false;
        click('#invNext');
        await settle();
        const sorted = items().pop().match(/sortBy=[^&]*&descending=\w+&startIndex=\d+/)[0];
        leave();
        await settle();
        failing = true;
        show();
        await settle();
        failing = false;
        const before = items().length;
        click('#invNext');
        await settle();
        const report = { pager: stale, asked: turned, sorted: sorted, revisit: items().length - before };
        window.close();
        return report;
    }

    if (mode === 'switch') {
        failing = true;
        page.querySelectorAll('.invType')[1].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
        await settle();
        const report = {
            selected: all('.invType.selected').join(','),
            rows: page.querySelectorAll('#invBody tr').length,
            headers: page.querySelectorAll('#invHead th').length,
            totals: page.querySelector('#invTotals').textContent.trim(),
            columns: page.querySelector('#invColumnsBtn').disabled,
            boxes: page.querySelectorAll('#invGroups input').length,
            pager: [page.querySelector('#invPage').textContent, page.querySelector('#invPrev').disabled,
                page.querySelector('#invNext').disabled].join('/'),
        };
        window.close();
        return report;
    }

    if (mode === 'stuck') {
        const twisty = () => page.querySelector('#invBody .invTwisty');
        twisty().dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
        await settle();
        const opened = twisty().getAttribute('aria-expanded');
        // Sorted while the children are on their way, and that request fails, so the rows stay.
        failing = true;
        page.querySelector('#invHead th').dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
        await settle();
        failing = false;
        held.open();
        await settle();
        const report = {
            opened: opened,
            after: twisty().getAttribute('aria-expanded'),
            children: page.querySelectorAll('#invBody tr[data-depth="1"]').length,
        };
        window.close();
        return report;
    }

    if (mode === 'export') {
        click('#invCsv');
        await settle();
        const during = disabled() + ',' + spinning();
        // A click anywhere in the table while the file is still coming.
        page.querySelectorAll('.invType')[1].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
        await settle();
        download.open();
        await settle();
        const report = { during: during, after: disabled() + ',' + spinning() };
        window.close();
        return report;
    }

    const text = (selector) => (page.querySelector(selector)?.textContent ?? '').trim();
    const grid = [...page.querySelectorAll('#invBody tr')]
        .map((tr) => [...tr.children].map((td) => td.textContent.trim()).join(' | '));

    const report = {
        query: asked.filter((url) => url.startsWith('Inventory/Items'))[0] ?? '',
        headers: all('#invHead th').join(','),
        rows: grid.length,
        tabs: all('.invType').join(','),
        link: page.querySelector('#invBody a')?.getAttribute('href') ?? '',
        grid: grid.join(' / '),
        totals: text('#invTotals'),
        pager: text('#invPage'),
        spinningWhileLoading: waiting,
        spinningAfterwards: spinning(),
    };
    window.close();
    return report;
}

const many = await render(read(itemFiles[0]));
for (const [key, value] of Object.entries(many)) { console.log(`${key}=${value}`); }

for (const [prefix, file] of [['one', itemFiles[1]], ['exact', itemFiles[2]]]) {
    if (!file) { continue; }
    const one = await render(read(file));
    for (const key of ['rows', 'grid', 'totals', 'pager', 'headers']) {
        console.log(`${prefix}.${key}=${one[key]}`);
    }
}

for (const mode of ['hide', 'export', 'stale', 'overlay', 'hung', 'failed', 'retry', 'stuck', 'switch']) {
    const extra = await render(read(itemFiles[0]), mode);
    for (const [key, value] of Object.entries(extra)) { console.log(`${mode}.${key}=${value}`); }
}

console.log(`raised=${raised.length}`);
