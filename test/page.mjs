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
    let shrunk = false;
    const schemaGates = [gate(), gate()];
    const held = gate();
    const rows = gate();
    // A tab with a level under it, so its rows carry a control that opens them.
    const openable = JSON.parse(JSON.stringify(items));
    openable.Rows.forEach(function (row) { row.Expandable = true; });
    const deep = JSON.parse(JSON.stringify(schema));
    deep.MediaTypes[0].Levels.push({ Level: 'Child', Label: 'Children' });
    deep.MediaTypes[0].ExpandedTo = null;
    deep.MaxFilters = 2;
    const download = gate();
    const asked = [];
    const fetched = [];
    const posted = [];
    const narrowed = JSON.parse(JSON.stringify(schema));
    narrowed.Columns = narrowed.Columns.filter((column) => column.Key !== 'videoCodec');
    // The second visit finds a library that has changed, so a discarded answer is visible.
    const changed = JSON.parse(JSON.stringify(schema));
    changed.MediaTypes.forEach(function (type) { type.Label = 'New ' + type.Label; });

    const dom = new JSDOM(source, {
        runScripts: 'dangerously',
        url: 'http://localhost/web/index.html',
        virtualConsole: new VirtualConsole()
            .on('jsdomError', (e) => { if (!e.message.startsWith('Not implemented')) { raised.push(e.message); } }),
        beforeParse(window) {
            window.ApiClient = {
                serverId: () => 'server',
                accessToken: () => 'token',
                getUrl: (path, params) => path + '?' + new window.URLSearchParams(params || {}),
                getJSON: (url) => {
                    asked.push(url);
                    if (url.startsWith('Inventory/Schema')) {
                        if (mode === 'stuck' || mode === 'filter' || mode === 'tree') { return Promise.resolve(deep); }
                        const call = ++served;
                        if (mode === 'gone') { return Promise.resolve(call > 1 ? narrowed : schema); }
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

                        if (mode === 'tree' && url.includes('parentIds=')) {
                            const ids = new window.URLSearchParams(url.split('?')[1]).get('parentIds').split(',');
                            return Promise.resolve({ ...items, Rows: ids.flatMap((id) => [1, 2].map((n) => (
                                { Id: id + '-' + n, ParentId: id, Expandable: false, Values: { name: 'child ' + n } }))) });
                        }

                        if (mode === 'stuck' || mode === 'filter' || mode === 'tree') { return Promise.resolve(openable); }
                        if (shrunk) {
                            const kept = /startIndex=0\b/.test(url) ? items.Rows.slice(0, 2) : [];
                            return Promise.resolve({ ...items, Rows: kept, TotalCount: 2 });
                        }

                        // Held so the busy state can be read while the rows are still on their way.
                        return mode === 'stale' || mode === 'overlay'
                            ? Promise.resolve(items)
                            : rows.held.then(() => items);
                    }

                    return Promise.reject(new Error('unexpected ' + url));
                },
                ajax: (options) => (posted.push(options), Promise.resolve({})),
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
            window.fetch = (target) => (fetched.push(target), mode === 'hung' && ++downloads === 1
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
    const requests = () => asked.filter((url) => url.startsWith('Inventory/Items'));
    const param = (url, key) => new URL(url, 'http://localhost/').searchParams.get(key);
    const change = (node, value, event) => {
        node.value = value;
        node.dispatchEvent(new window.Event(event, { bubbles: true }));
    };
    const typed = () => new Promise((done) => window.setTimeout(done, 400));

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
        const turned = requests().pop().match(/startIndex=\d+/)[0];
        failing = true;
        page.querySelector('#invHead th').dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
        await settle();
        failing = false;
        click('#invNext');
        await settle();
        const sorted = requests().pop().match(/sortBy=[^&]*&descending=\w+&startIndex=\d+/)[0];
        leave();
        await settle();
        failing = true;
        show();
        await settle();
        failing = false;
        const before = requests().length;
        click('#invNext');
        await settle();
        const report = { pager: stale, asked: turned, sorted: sorted, revisit: requests().length - before };
        window.close();
        return report;
    }

    if (mode === 'beyond') {
        // Two of the seven rows are left by the time the next page is asked for.
        shrunk = true;
        const before = asked.length;
        click('#invNext');
        await settle();
        const report = {
            asked: asked.slice(before).map((url) => url.match(/startIndex=(\d+)/)[1]).join(','),
            rows: page.querySelectorAll('#invBody tr').length,
            pager: page.querySelector('#invPage').textContent.trim(),
        };
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

    if (mode === 'filter') {
        const twisties = () => page.querySelectorAll('#invBody .invTwisty').length;
        const before = twisties();
        // Expanded one level down, which is the level a filter then lists.
        change(page.querySelector('#invExpand'), '1', 'change');
        await settle();
        click('#invFilterBtn');
        await settle();
        const waiting = requests().length;
        change(page.querySelector('#invFilters select'), 'size', 'change');
        await typed();
        const idle = requests().length - waiting;
        change(page.querySelector('#invFilters input'), '1.5', 'input');
        await typed();
        await settle();
        const last = new URL(requests().pop(), 'http://localhost/');
        const report = {
            sent: last.searchParams.get('filters'),
            level: 'level=' + last.searchParams.get('level') + '&columnLevel=' + last.searchParams.get('columnLevel'),
            before: before,
            after: twisties(),
            idle: idle,
            button: page.querySelector('#invFilterBtn').textContent.trim(),
        };
        click('#invCsv');
        await settle();
        const file = new URL(fetched.pop(), 'http://localhost/');
        report.exported = ['level', 'columnLevel', 'filters']
            .map((key) => file.searchParams.get(key) === last.searchParams.get(key)).join(',');
        click('#invFilterAdd');
        await settle();
        report.capped = page.querySelector('#invFilterAdd').disabled;
        const second = () => page.querySelectorAll('#invFilters .invFilter')[1];
        change(second().querySelector('.invOp select'), 'empty', 'change');
        await settle();
        report.bare = new URL(requests().pop(), 'http://localhost/').searchParams.get('filters');
        report.valueless = second().querySelectorAll('input').length;
        click('#invFilters .invDrop');
        await settle();
        report.freed = page.querySelector('#invFilterAdd').disabled;
        click('#invFilters .invDrop');
        await settle();
        report.restored = twisties();
        window.close();
        return report;
    }

    if (mode === 'tree') {
        const depths = () => [...page.querySelectorAll('#invBody tr')].map((tr) => tr.getAttribute('data-depth')).join(',');
        click('#invBody .invTwisty');
        await settle();
        const opened = depths() + '/' + all('#invBody tr[data-depth="1"] td:first-child').join(',');
        click('#invBody .invTwisty');
        await settle();
        const report = { opened: opened, closed: depths() };
        window.close();
        return report;
    }

    if (mode === 'twice') {
        // The web client keeps the view it left, and a second address for this page adds another.
        leave();
        await settle();
        const copy = new window.DOMParser().parseFromString(source, 'text/html').querySelector('#InventoryPage');
        const code = copy.querySelector('script').textContent;
        // Taken out before the copy is inserted, since jsdom runs a script that arrives with it.
        copy.querySelector('script').remove();
        const second = window.document.importNode(copy, true);
        window.document.body.appendChild(second);
        const script = window.document.createElement('script');
        script.textContent = code;
        window.document.body.appendChild(script);
        const schemas = asked.filter((url) => url.startsWith('Inventory/Schema')).length;
        second.dispatchEvent(new window.Event('pageshow'));
        await settle();
        const exported = fetched.length;
        second.querySelector('#invCsv').dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
        await settle();
        const report = {
            tabs: second.querySelectorAll('.invType').length,
            schemas: asked.filter((url) => url.startsWith('Inventory/Schema')).length - schemas,
            exports: fetched.length - exported,
        };
        window.close();
        return report;
    }

    if (mode === 'revisit') {
        page.querySelectorAll('#invHead th')[1].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
        await settle();
        click('#invNext');
        await settle();
        leave();
        await settle();
        show();
        await settle();
        const report = { asked: requests().pop().match(/sortBy=[^&]*&descending=\w+&startIndex=\d+/)[0] };
        window.close();
        return report;
    }

    if (mode === 'debounce') {
        click('#invNext');
        await settle();
        click('#invNext');
        await settle();
        click('#invFilterBtn');
        await settle();
        change(page.querySelector('#invFilters input'), 'a', 'input');
        // Paged back before the pause after typing is over.
        click('#invPrev');
        await settle();
        const report = { asked: 'startIndex=' + param(requests().pop(), 'startIndex') };
        await typed();
        report.pager = page.querySelector('#invPage').textContent.trim();
        window.close();
        return report;
    }

    if (mode === 'gone') {
        click('#invFilterBtn');
        await settle();
        change(page.querySelector('#invFilters select'), 'videoCodec', 'change');
        await settle();
        change(page.querySelector('#invFilters input'), 'h264', 'input');
        await typed();
        leave();
        await settle();
        const before = requests().length;
        show();
        await settle();
        const report = {
            asked: requests().length - before,
            button: page.querySelector('#invFilterBtn').textContent.trim(),
            rows: page.querySelectorAll('#invBody tr').length,
        };
        window.close();
        return report;
    }

    if (mode === 'units') {
        click('#invFilterBtn');
        await settle();
        const sent = [];
        const invalid = [];
        for (const [column, value] of [['duration', '90'], ['totalBitrate', '128'], ['sizePerHour', '2'],
            ['size', '1,5'], ['size', 'abc'], ['dateAdded', '20245-01-01'], ['dateAdded', '2024-03-01'], ['interlaced', null]]) {
            if (page.querySelector('#invFilters select').value !== column) {
                change(page.querySelector('#invFilters select'), column, 'change');
                await settle();
            }

            const box = page.querySelector('#invFilters input');
            if (value !== null) { change(box, value, 'input'); }
            await typed();
            const filters = param(requests().pop(), 'filters');
            sent.push(filters ? JSON.parse(filters)[0].value : 'none');
            invalid.push(box ? box.getAttribute('aria-invalid') : '-');
        }

        const report = { sent: sent.join('|'), invalid: invalid.join('|') };
        window.close();
        return report;
    }

    if (mode === 'controls') {
        const header = (key) => page.querySelector(`#invHead th[data-key="${key}"]`);
        click('#invColumnsBtn');
        await settle();
        const year = page.querySelector('#invGroups input[data-key="year"]');
        year.checked = true;
        year.dispatchEvent(new window.Event('change', { bubbles: true }));
        await settle();
        const report = { ticked: posted.pop().data };
        header('size').dispatchEvent(new window.KeyboardEvent('keydown', { key: 'ArrowLeft', ctrlKey: true, bubbles: true }));
        await settle();
        report.moved = posted.pop().data;
        const sorted = [];
        for (const key of ['size', 'size', 'name']) {
            header(key).dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
            await settle();
            sorted.push(key + '=' + param(requests().pop(), 'descending'));
        }

        report.sorted = sorted.join(',');
        change(page.querySelector('#invSize'), '250', 'change');
        await settle();
        const last = requests().pop();
        report.size = posted.pop().url + '/' + param(last, 'startIndex') + ',' + param(last, 'limit');
        change(page.querySelector('#invSearch'), 'Blue', 'input');
        await typed();
        report.search = param(requests().pop(), 'search');
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
        brand: ['href', 'target', 'rel'].map((key) => page.querySelector('.invBrand a').getAttribute(key))
            .concat(text('.invBrand a')).join('|'),
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

for (const mode of ['hide', 'export', 'stale', 'overlay', 'hung', 'failed', 'retry', 'stuck', 'switch', 'beyond', 'filter',
    'tree', 'twice', 'revisit', 'debounce', 'gone', 'units', 'controls']) {
    const extra = await render(read(itemFiles[0]), mode);
    for (const [key, value] of Object.entries(extra)) { console.log(`${mode}.${key}=${value}`); }
}

console.log(`raised=${raised.length}`);
