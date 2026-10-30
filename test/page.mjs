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
    const saved = [];
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
    const picking = ['toolbar', 'pick', 'scope', 'remove', 'late', 'pages', 'overcount', 'nested'].includes(mode);
    const toasts = [];
    const targets = {
        Collections: [{ Id: 'c1', Name: 'Classics' }, { Id: 'c2', Name: 'Rainy, Weekend' }],
        Playlists: mode === 'remove' ? null : [{ Id: 'p1', Name: 'Road trip' }],
    };
    const answer = { Count: 5, Skipped: 1, fail: false };
    // A page of the size asked for, so the table has more matches than rows.
    const paged = (url, from) => {
        const query = new URLSearchParams(url.split('?')[1]);
        const start = Number(query.get('startIndex')) || 0;
        return { ...from, Rows: from.Rows.slice(start, start + Number(query.get('limit') || 100)) };
    };
    // A gate set here holds that kind of answer until the run opens it.
    const slow = { items: null, targets: null, posted: null };
    const after = (kind, value) => (slow[kind] ? slow[kind].held.then(() => value) : Promise.resolve(value));

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
                        if (mode === 'down' || (mode === 'offline' && failing)) { return Promise.reject(new Error('no')); }
                        if (mode === 'stuck' || mode === 'filter' || mode === 'tree' || mode === 'nested') { return Promise.resolve(deep); }
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

                        if ((mode === 'tree' || mode === 'nested') && url.includes('parentIds=')) {
                            const ids = new window.URLSearchParams(url.split('?')[1]).get('parentIds').split(',');
                            return Promise.resolve({ ...items, Rows: ids.flatMap((id) => [1, 2].map((n) => (
                                { Id: id + '-' + n, ParentId: id, Expandable: false, Values: { name: 'child ' + n } }))) });
                        }

                        if (mode === 'stuck' || mode === 'filter' || mode === 'tree') { return Promise.resolve(openable); }
                        if (picking) { return after('items', paged(url, mode === 'nested' ? openable : items)); }
                        if (shrunk) {
                            const kept = /startIndex=0\b/.test(url) ? items.Rows.slice(0, 2) : [];
                            return Promise.resolve({ ...items, Rows: kept, TotalCount: 2 });
                        }

                        // Held so the busy state can be read while the rows are still on their way.
                        return mode === 'stale' || mode === 'overlay'
                            ? Promise.resolve(items)
                            : rows.held.then(() => items);
                    }

                    if (url.startsWith('Inventory/Targets') && picking) { return after('targets', JSON.parse(JSON.stringify(targets))); }
                    return Promise.reject(new Error('unexpected ' + url));
                },
                ajax: (options) => {
                    posted.push(options);
                    if (!options.url.startsWith('Inventory/Targets')) { return Promise.resolve({}); }
                    const body = JSON.parse(options.data);
                    if (options.url.startsWith('Inventory/Targets/Held')) {
                        // Only the server knows where an all-selection is, so one is taken to be in the first collection and every playlist.
                        const holds = !!body.All || body.Ids.includes(items.Rows[0].Id);
                        return after('targets', {
                            Collections: holds ? [targets.Collections[0]] : [],
                            Playlists: targets.Playlists && (holds ? targets.Playlists : []),
                        });
                    }
                    if (answer.fail) { return Promise.reject(new Error('no')); }
                    const known = targets.Collections.concat(targets.Playlists || []).filter((target) => target.Id === body.Id)[0];
                    return after('posted', { Id: body.Id || 'n1', Name: known ? known.Name : body.Name, Count: answer.Count, Skipped: answer.Skipped });
                },
            };
            window.Dashboard = {
                showLoadingMsg() { overlay++; },
                hideLoadingMsg() { overlay = 0; },
                alert(message) {
                    toasts.push(message);
                    if (!picking && !['failed', 'retry', 'stuck', 'switch', 'down', 'offline'].includes(mode)) {
                        throw new Error('the page gave up: ' + message);
                    }
                },
            };
            // jsdom has the element but neither of its methods.
            window.HTMLDialogElement.prototype.showModal = function () { this.setAttribute('open', ''); };
            window.HTMLDialogElement.prototype.close = function () { this.removeAttribute('open'); };
            window.URL.createObjectURL = () => 'blob:export';
            window.URL.revokeObjectURL = () => {};
            window.HTMLAnchorElement.prototype.click = function () { saved.push(this.download); };
            // The first export of a hung run never lands, the way a half open connection behaves.
            window.fetch = (target) => (fetched.push(target), mode === 'hung' && ++downloads === 1
                ? new Promise(() => {})
                : download.held.then(() => ({
                    ok: true,
                    headers: { get: (name) => (name === 'Content-Disposition' ? 'attachment; filename=inventory-sent.csv' : null) },
                    blob: () => Promise.resolve('bytes'),
                })));
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

    if (mode === 'rtl') { window.document.documentElement.setAttribute('dir', 'rtl'); }
    // An interface language with digits of its own and no strings of the plugin's.
    if (mode === 'toolbar') { window.document.documentElement.setAttribute('lang', 'mr'); }
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

    if (mode === 'failed' || mode === 'down') {
        const report = {
            message: page.querySelector('#invEmpty').textContent.trim(),
            shown: page.querySelector('#invEmpty').style.display !== 'none',
            columns: page.querySelector('#invColumnsBtn').disabled,
            dead: ['#invColumnsBtn', '#invCsv', '#invOds', '#invPrev', '#invNext']
                .map((id) => page.querySelector(id).disabled).join(','),
        };
        window.close();
        return report;
    }

    if (mode === 'offline') {
        leave();
        await settle();
        failing = true;
        show();
        await settle();
        const report = {
            filters: page.querySelector('#invFilterBtn').disabled,
            rows: page.querySelectorAll('#invBody tr').length,
        };
        window.close();
        return report;
    }

    if (mode === 'scroll') {
        const scroller = page.querySelector('.invScroll');
        scroller.scrollTop = 300;
        click('#invColumnsBtn');
        const year = page.querySelector('#invGroups input[data-key="year"]');
        year.checked = true;
        year.dispatchEvent(new window.Event('change', { bubbles: true }));
        await settle();
        const kept = scroller.scrollTop;
        click('#invNext');
        await settle();
        const report = { kept: kept, turned: scroller.scrollTop };
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
            select: page.querySelector('#invPickBtn').disabled,
            boxes: page.querySelectorAll('#invGroups input').length,
            pager: [page.querySelector('#invPage').textContent, page.querySelector('#invPrev').disabled,
                page.querySelector('#invNext').disabled].join('/'),
        };
        window.close();
        return report;
    }

    if (mode === 'early') {
        const before = requests().length;
        page.querySelectorAll('.invType')[1].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
        page.querySelectorAll('#invHead th')[1].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
        await settle();
        const report = { sorts: requests().slice(before).map((url) => param(url, 'sortBy') || '-').join(',') };
        window.close();
        return report;
    }

    if (mode === 'rtl') {
        const cells = [...page.querySelectorAll('#invBody td')];
        const report = {
            bare: cells.filter((td) => [...td.childNodes].some((node) => node.nodeType === 3 && node.nodeValue)).length,
            name: page.querySelector('#invBody td a').dir,
            totals: page.querySelectorAll('#invTotals bdi').length,
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
            ['size', '1,5'], ['audioSampleRate', '48,000'], ['frameRate', '23,976'], ['size', '0,125'], ['size', 'abc'], ['dateAdded', '20245-01-01'], ['dateAdded', '2024-03-01'], ['interlaced', null],
            ['quality', null]]) {
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

        const classes = page.querySelectorAll('#invFilters select')[2];
        change(classes, '720p', 'change');
        await settle();
        const report = {
            sent: sent.join('|'),
            invalid: invalid.join('|'),
            classes: [...classes.options].map((option) => option.value).join(','),
            picked: JSON.parse(param(requests().pop(), 'filters'))[0].value,
        };
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
        const report = { during: during, after: disabled() + ',' + spinning(), saved: saved.at(-1) };
        window.close();
        return report;
    }

    const text = (selector) => (page.querySelector(selector)?.textContent ?? '').trim();
    const press = (node, key) => node.dispatchEvent(new window.KeyboardEvent('keydown', { key: key, bubbles: true }));
    const focused = () => window.document.activeElement.id || '-';
    const boxes = () => [...page.querySelectorAll('#invBody td.invPick input')];
    const picked = () => page.querySelector('#invPickCount').textContent;
    const pressed = () => page.querySelector('#invPickBtn').getAttribute('aria-pressed');
    const tab = async (index) => {
        page.querySelectorAll('.invType')[index].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
        await settle();
    };
    const groups = () => [...page.querySelectorAll('#invTarget optgroup')]
        .map((group) => group.label + ':' + [...group.children].map((option) => option.textContent).join(',')).join('|');
    const submit = async () => {
        page.querySelector('#invDialogForm').requestSubmit();
        await settle();
    };

    if (mode === 'toolbar') {
        const menu = page.querySelector('#invExportMenu');
        const report = {
            names: ['#invColumnsBtn', '#invFilterBtn', '#invPickBtn', '#invExportBtn', '#invPrev', '#invNext']
                .map((id) => page.querySelector(id).title + '=' + page.querySelector(id).textContent.trim()).join(','),
            pager: [!!page.querySelector('#invPrev svg'), page.querySelector('#invPrev').disabled,
                text('#invPage'), page.querySelector('#invNext').disabled].join('/'),
        };
        const where = () => (menu.hidden ? 'closed' : 'open') + ':' + focused();
        const steps = [];
        click('#invExportBtn');
        steps.push(where());
        press(window.document.activeElement, 'ArrowDown');
        steps.push(focused());
        press(window.document.activeElement, 'Escape');
        steps.push(where());
        click('#invExportBtn');
        window.document.body.dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
        steps.push(menu.hidden ? 'closed' : 'open');
        click('#invExportBtn');
        page.querySelector('#invCsv').dispatchEvent(new window.FocusEvent('focusout', { bubbles: true, relatedTarget: page.querySelector('#invSearch') }));
        steps.push(menu.hidden ? 'closed' : 'open');
        click('#invExportBtn');
        click('#invOds');
        await settle();
        steps.push((menu.hidden ? 'closed' : 'open') + ':' + param(fetched.at(-1), 'format') + ':' + spinning());
        download.open();
        await settle();
        report.menu = steps.join(',');

        const filter = page.querySelector('#invFilterBtn');
        click('#invFilterBtn');
        await settle();
        change(page.querySelector('#invFilters input'), 'Blue', 'input');
        await typed();
        report.badge = [filter.getAttribute('data-count'), filter.getAttribute('aria-label'), filter.title].join('|');
        click('#invFilters .invDrop');
        await settle();
        report.unbadged = filter.hasAttribute('data-count') + '|' + filter.getAttribute('aria-label');

        const enabled = [];
        for (const index of [0, 3, 5]) {
            await tab(index);
            enabled.push(!page.querySelector('#invPickBtn').disabled);
        }
        report.pickable = enabled.join(',');
        window.close();
        return report;
    }

    if (mode === 'pick') {
        const head = () => page.querySelector('#invPickPage');
        const widen = page.querySelector('#invPickAll');
        const bar = () => page.querySelector('#invPickBar').style.display || 'shown';
        const away = bar();
        click('#invPickBtn');
        const report = {
            entered: [pressed(), away, bar(), page.querySelector('#invTypes').style.visibility,
                page.querySelectorAll('#invHead th.invPick').length, boxes().length, picked(),
                page.querySelector('#invAddTo').disabled].join('/'),
        };
        boxes()[0].click();
        report.one = [picked(), head().indeterminate, page.querySelector('#invBody tr').classList.contains('invPicked'),
            page.querySelector('#invAddTo').disabled, widen.style.display].join('/');
        head().click();
        report.page = [picked(), head().checked, head().indeterminate, widen.style.display, widen.textContent].join('/');
        widen.click();
        report.all = [picked(), widen.style.display].join('/');
        boxes()[1].click();
        report.except = picked();
        click('#invNext');
        await settle();
        report.turned = picked() + '/' + boxes().map((box) => box.checked).join(',');
        click('#invPrev');
        await settle();
        report.back = boxes().map((box) => box.checked).join(',');

        click('#invAddTo');
        await settle();
        const dialog = page.querySelector('#invDialog');
        report.groups = groups();
        report.fresh = [dialog.open, page.querySelector('#invTarget').value, page.querySelector('#invNameField').style.display || 'shown',
            page.querySelector('#invName').required].join('/');
        change(page.querySelector('#invTarget'), 'Collection:c1', 'change');
        report.existing = [page.querySelector('#invNameField').style.display, page.querySelector('#invName').required].join('/');
        const before = requests().length;
        await submit();
        report.allBody = posted.at(-1).data;
        report.done = [toasts.at(-1), dialog.open, pressed(), page.querySelectorAll('.invPick').length,
            requests().length - before].join('/');

        click('#invPickBtn');
        boxes()[0].click();
        boxes()[1].click();
        click('#invAddTo');
        await settle();
        change(page.querySelector('#invTarget'), 'Playlist:', 'change');
        change(page.querySelector('#invName'), 'Draft', 'input');
        press(page.querySelector('#invDialogOk'), 'Escape');
        report.escaped = pressed();
        click('#invDialogCancel');
        click('#invAddTo');
        await settle();
        report.reopened = page.querySelector('#invTarget').value + '/' + page.querySelector('#invName').value;
        change(page.querySelector('#invTarget'), 'Playlist:', 'change');
        const sent = posted.length;
        change(page.querySelector('#invName'), '   ', 'input');
        await submit();
        report.blank = posted.length - sent;
        change(page.querySelector('#invName'), ' Rock $& Mix ', 'input');
        answer.Skipped = 3;
        await submit();
        report.tickedBody = posted.at(-1).data;
        report.toast = toasts.at(-1);
        click('#invPickBtn');
        boxes()[0].click();
        click('#invAddTo');
        await settle();
        change(page.querySelector('#invTarget'), 'Collection:c1', 'change');
        answer.Count = 0;
        answer.Skipped = 0;
        await submit();
        report.already = toasts.at(-1);

        const leaving = [];
        click('#invPickBtn');
        boxes()[0].click();
        click('#invPickBtn');
        leaving.push(pressed() + ':' + page.querySelectorAll('.invPick').length + ':' + bar());
        click('#invPickBtn');
        boxes()[0].click();
        page.querySelector('#invPickEnd').focus();
        click('#invPickEnd');
        leaving.push(pressed() + ':' + page.querySelectorAll('.invPick').length + ':' + focused());
        click('#invPickBtn');
        boxes()[0].click();
        press(page.querySelector('#invSearch'), 'Escape');
        leaving.push(pressed());
        boxes()[0].focus();
        press(boxes()[0], 'Escape');
        leaving.push(pressed() + ':' + focused());
        click('#invPickBtn');
        leaving.push(picked());
        await tab(1);
        leaving.push(pressed());
        report.leaving = leaving.join(',');
        window.close();
        return report;
    }

    if (mode === 'scope') {
        change(page.querySelector('#invSize'), '50', 'change');
        await settle();
        click('#invPickBtn');
        page.querySelector('#invPickPage').click();
        const report = { whole: picked() + '/' + page.querySelector('#invPickAll').style.display };
        page.querySelector('#invPickPage').click();
        boxes()[1].click();
        boxes()[4].dispatchEvent(new window.MouseEvent('click', { bubbles: true, shiftKey: true }));
        report.range = picked() + '/' + boxes().map((box) => (box.checked ? 1 : 0)).join('');
        boxes()[2].dispatchEvent(new window.MouseEvent('click', { bubbles: true, shiftKey: true }));
        report.unranged = picked() + '/' + boxes().map((box) => (box.checked ? 1 : 0)).join('');
        change(page.querySelector('#invSize'), '2', 'change');
        await settle();
        page.querySelector('#invPickPage').click();
        page.querySelector('#invPickAll').click();
        const all = picked();
        change(page.querySelector('#invSearch'), 'Blue', 'input');
        await typed();
        await settle();
        report.searched = all + '/' + picked() + '/' + pressed();
        window.close();
        return report;
    }

    if (mode === 'remove') {
        click('#invPickBtn');
        boxes()[1].click();
        click('#invRemoveFrom');
        await settle();
        const dialog = page.querySelector('#invDialog');
        const report = { nothing: toasts.at(-1) + '/' + dialog.open };
        boxes()[0].click();
        click('#invRemoveFrom');
        await settle();
        report.groups = groups() + '/' + (page.querySelector('#invNameField').style.display || 'shown');
        answer.Count = 1;
        answer.Skipped = 0;
        await submit();
        report.body = posted.at(-1).data;
        report.toast = toasts.at(-1);

        targets.Playlists = [{ Id: 'p1', Name: 'Road trip' }];
        click('#invPickBtn');
        page.querySelector('#invPickPage').click();
        page.querySelector('#invPickAll').click();
        click('#invRemoveFrom');
        await settle();
        report.held = posted.at(-1).data;
        report.playlists = groups();
        change(page.querySelector('#invTarget'), 'Playlist:p1', 'change');
        await submit();
        report.unlisted = posted.at(-1).data + '/' + toasts.at(-1);

        await tab(3);
        click('#invPickBtn');
        boxes()[0].click();
        click('#invAddTo');
        await settle();
        report.books = groups();
        change(page.querySelector('#invName'), 'Shelf', 'input');
        answer.fail = true;
        const before = requests().length;
        await submit();
        report.failed = [toasts.at(-1), dialog.open, pressed(), picked(), requests().length - before].join('/');
        window.close();
        return report;
    }

    if (mode === 'late') {
        const dialog = page.querySelector('#invDialog');
        const widen = page.querySelector('#invPickAll');
        click('#invPickBtn');
        page.querySelector('#invPickPage').click();
        slow.targets = gate();
        click('#invAddTo');
        await settle();
        boxes()[1].click();
        slow.targets.open();
        await settle();
        const report = { unticked: dialog.open + '/' + picked() };
        boxes()[1].click();
        widen.click();
        slow.targets = gate();
        click('#invAddTo');
        await settle();
        change(page.querySelector('#invSearch'), 'Blue', 'input');
        await typed();
        await settle();
        slow.targets.open();
        await settle();
        report.searched = dialog.open + '/' + picked();

        boxes()[0].click();
        const since = asked.length;
        change(page.querySelector('#invSearch'), 'Night', 'input');
        click('#invAddTo');
        await settle();
        report.typed = asked.slice(since).map((url) => url.split('?')[0] + (param(url, 'search') ? '=' + param(url, 'search') : '')).join(',')
            + '/' + dialog.open;

        change(page.querySelector('#invTarget'), 'Collection:c1', 'change');
        slow.posted = gate();
        await submit();
        const cancel = new window.Event('cancel', { cancelable: true });
        dialog.dispatchEvent(cancel);
        page.querySelector('#invDialogCancel').click();
        // The button under the caret is disabled, which drops the focus to the body.
        const escape = new window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true });
        window.document.body.dispatchEvent(escape);
        report.sending = [dialog.open, page.querySelector('#invDialogCancel').disabled, cancel.defaultPrevented,
            escape.defaultPrevented, pressed()].join('/');
        slow.posted.open();
        await settle();
        report.sent = [dialog.open, pressed(), page.querySelector('#invDialogCancel').disabled].join('/');

        click('#invPickBtn');
        page.querySelector('#invPickPage').click();
        const offered = widen.style.display + ':' + widen.textContent;
        slow.items = gate();
        change(page.querySelector('#invSearch'), '', 'input');
        await typed();
        await settle();
        report.loading = offered + '/' + widen.style.display;
        slow.items.open();
        await settle();
        report.loaded = widen.style.display + ':' + widen.textContent;

        click('#invAddTo');
        await settle();
        change(page.querySelector('#invTarget'), 'Collection:c1', 'change');
        slow.posted = gate();
        await submit();
        const told = toasts.length;
        leave();
        slow.posted.open();
        await settle();
        report.left = toasts.length - told;
        window.close();
        return report;
    }

    if (mode === 'pages') {
        const widen = page.querySelector('#invPickAll');
        const head = () => page.querySelector('#invPickPage');
        const turn = async (selector) => {
            click(selector);
            await settle();
        };
        click('#invPickBtn');
        head().click();
        widen.click();
        await turn('#invNext');
        head().click();
        const report = { header: picked() + '/' + boxes().map((box) => box.checked).join(',') };
        await turn('#invPrev');
        report.others = boxes().map((box) => box.checked).join(',');
        head().click();
        await turn('#invNext');
        await turn('#invNext');
        head().click();
        await turn('#invNext');
        boxes()[0].click();
        report.last = picked();
        head().click();
        report.again = [picked(), widen.style.display, widen.textContent].join('/');
        widen.click();
        for (let left = 4; left > 0; left--) {
            head().click();
            if (left > 1) { await turn('#invPrev'); }
        }
        report.emptied = picked();
        head().click();
        report.emptied += '/' + widen.style.display;
        window.close();
        return report;
    }

    if (mode === 'overcount') {
        click('#invPickBtn');
        change(page.querySelector('#invSearch'), 'Blue', 'input');
        await typed();
        await settle();
        boxes()[0].click();
        change(page.querySelector('#invSearch'), '', 'input');
        await typed();
        await settle();
        click('#invNext');
        await settle();
        page.querySelector('#invPickPage').click();
        page.querySelector('#invPickAll').click();
        const report = { all: picked() };
        click('#invAddTo');
        await settle();
        change(page.querySelector('#invTarget'), 'Collection:c1', 'change');
        await submit();
        report.body = posted.at(-1).data;
        window.close();
        return report;
    }

    if (mode === 'nested') {
        const rows = () => [...page.querySelectorAll('#invBody tr')]
            .map((tr) => tr.getAttribute('data-depth') + (tr.querySelector('td.invPick input') ? 'x' : '-')).join(',');
        const pick = async (target) => {
            change(page.querySelector('#invTarget'), target, 'change');
            await submit();
            return posted.at(-1).data;
        };
        click('#invPickBtn');
        click('#invBody .invTwisty');
        await settle();
        const report = { opened: rows() };
        page.querySelector('#invBody tr[data-depth="1"] td.invPick input')?.click();
        report.child = picked() + '/' + page.querySelector('#invBody tr[data-depth="1"]').classList.contains('invPicked');
        page.querySelector('#invPickPage').click();
        page.querySelector('#invPickAll').click();
        report.kept = picked();
        click('#invAddTo');
        await settle();
        report.keptBody = await pick('Collection:c1');

        // Reads of the table while a level opens, which have to stay the same however many rows it opens under.
        const reads = { count: 0 };
        for (const kind of [window.Element, window.Document]) {
            const native = kind.prototype.querySelectorAll;
            kind.prototype.querySelectorAll = function (selector) {
                reads.count++;
                return native.call(this, selector);
            };
        }
        const opening = async () => {
            change(page.querySelector('#invExpand'), '0', 'change');
            await settle();
            reads.count = 0;
            change(page.querySelector('#invExpand'), '1', 'change');
            await settle();
            return reads.count;
        };
        const walks = [];
        for (const on of [false, true]) {
            if (on) {
                click('#invPickBtn');
                report.boxed = rows();
            }
            const few = await opening();
            change(page.querySelector('#invSize'), '50', 'change');
            await settle();
            const many = await opening();
            walks.push(many - few + ':' + rows().split(',').filter((row) => row.endsWith(on ? 'x' : '-')).length);
            change(page.querySelector('#invSize'), '2', 'change');
            await settle();
        }
        report.walks = walks.join(',');

        click('#invFilterBtn');
        await settle();
        change(page.querySelector('#invFilters input'), 'a', 'input');
        await typed();
        await settle();
        page.querySelector('#invPickPage').click();
        page.querySelector('#invPickAll').click();
        page.querySelector('#invHead th[data-key="size"]').dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
        await settle();
        report.sorted = picked();
        click('#invAddTo');
        await settle();
        report.listedBody = await pick('Collection:c1');
        const dropped = [];
        for (const step of [
            () => change(page.querySelector('#invFilters input'), 'ab', 'input'),
            () => change(page.querySelector('#invExpand'), '0', 'change'),
        ]) {
            click('#invPickBtn');
            page.querySelector('#invPickPage').click();
            page.querySelector('#invPickAll').click();
            const all = picked();
            step();
            await typed();
            await settle();
            dropped.push(all + ':' + picked());
            click('#invPickBtn');
        }
        report.dropped = dropped.join(',');

        const widen = page.querySelector('#invPickAll');
        click('#invPickBtn');
        page.querySelector('#invPickPage').click();
        const offered = widen.style.display;
        slow.items = gate();
        change(page.querySelector('#invExpand'), '1', 'change');
        await settle();
        report.relisting = offered + '/' + widen.style.display;
        slow.items.open();
        await settle();
        window.close();
        return report;
    }

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

for (const mode of ['hide', 'export', 'stale', 'overlay', 'hung', 'failed', 'down', 'offline', 'retry', 'stuck', 'beyond',
    'filter', 'tree', 'twice', 'revisit', 'debounce', 'gone', 'units', 'scroll', 'controls', 'early', 'rtl']) {
    const extra = await render(read(itemFiles[0]), mode);
    for (const [key, value] of Object.entries(extra)) { console.log(`${mode}.${key}=${value}`); }
}

// Checked here, beside the stubs they answer; run.sh sees a mismatch as something raised.
const ids = read(itemFiles[0]).Rows.map((row) => row.Id);
const listing = (level, filters, except) => ({ MediaType: 'Movie', Level: level, Search: '', Filters: filters, Except: except });
const wanted = {
    switch: { select: 'true' },
    toolbar: {
        names: 'Columns=Columns,Filters=Filters,Select=Select,Export=Export,Previous=Previous,Next=Next',
        pager: 'true/true/1 / 4/false',
        menu: 'open:invCsv,invOds,closed:invExportBtn,closed,closed,closed:ods:1',
        badge: '१|Filters (१)|Filters (१)',
        unbadged: 'false|Filters',
        pickable: 'true,true,false',
    },
    pick: {
        entered: 'true/none/shown/hidden/1/2/0 selected/true',
        one: '1 selected/true/true/false/none',
        page: '2 selected/true/false//Select all 7',
        all: 'All 7 selected/none',
        except: '6 selected',
        turned: '6 selected/true,true',
        back: 'true,false',
        groups: 'Collections:New collection,Classics,Rainy, Weekend|Playlists:New playlist,Road trip',
        fresh: 'true/Collection:/shown/true',
        existing: 'none/false',
        allBody: JSON.stringify({ Kind: 'Collection', Remove: false, Id: 'c1', Name: null, Ids: [], All: listing('Movie', '', [ids[1]]) }),
        done: 'Added 5 items to "Classics". 1 item cannot be in it./false/false/0/1',
        escaped: 'true',
        reopened: 'Collection:/',
        blank: '0',
        tickedBody: JSON.stringify({ Kind: 'Playlist', Remove: false, Id: null, Name: 'Rock $& Mix', Ids: [ids[0], ids[1]], All: null }),
        toast: 'Added 5 items to "Rock $& Mix". 3 items cannot be in it.',
        already: 'Everything is already in "Classics".',
        leaving: 'false:0:none,false:0:invPickBtn,true,false:invPickBtn,0 selected,false',
    },
    scope: {
        whole: '7 selected/none',
        range: '4 selected/0111100',
        unranged: '1 selected/0100000',
        searched: 'All 7 selected/0 selected/true',
    },
    remove: {
        nothing: 'None of the selected items is in a collection or playlist./false',
        groups: 'Collections:Classics/none',
        body: JSON.stringify({ Kind: 'Collection', Remove: true, Id: 'c1', Name: null, Ids: [ids[1], ids[0]], All: null }),
        toast: 'Removed 1 item from "Classics".',
        held: JSON.stringify({ Ids: [], All: listing('Movie', '', []) }),
        playlists: 'Collections:Classics|Playlists:Road trip',
        unlisted: JSON.stringify({ Kind: 'Playlist', Remove: true, Id: 'p1', Name: null, Ids: [], All: listing('Movie', '', []) })
            + '/Removed 1 item from "Road trip".',
        books: 'Collections:New collection,Classics,Rainy, Weekend',
        failed: 'Could not change the collection or playlist./false/true/1 selected/0',
    },
    late: {
        unticked: 'false/1 selected',
        searched: 'false/0 selected',
        typed: 'Inventory/Items=Night,Inventory/Targets/true',
        sending: 'true/true/true/true/true',
        sent: 'false/false/false',
        loading: ':Select all 7/none',
        loaded: ':Select all 7',
        left: '0',
    },
    pages: {
        header: '5 selected/false,false',
        others: 'true,true',
        last: '0 selected',
        again: '1 selected//Select all 7',
        emptied: '0 selected/',
    },
    overcount: {
        all: 'All 7 selected',
        body: JSON.stringify({ Kind: 'Collection', Remove: false, Id: 'c1', Name: null, Ids: [], All: listing('Movie', '', []) }),
    },
    nested: {
        opened: '0x,1x,1x,0x',
        child: '1 selected/true',
        kept: '8 selected',
        keptBody: JSON.stringify({ Kind: 'Collection', Remove: false, Id: 'c1', Name: null, Ids: [ids[0] + '-1'], All: listing('Movie', '', []) }),
        boxed: '0x,1x,1x,0x,1x,1x',
        walks: '0:21,0:21',
        sorted: 'All 7 selected',
        listedBody: JSON.stringify({ Kind: 'Collection', Remove: false, Id: 'c1', Name: null, Ids: [],
            All: listing('Child', JSON.stringify([{ column: 'name', op: 'contains', value: 'a' }]), []) }),
        dropped: 'All 7 selected:0 selected,All 7 selected:0 selected',
        relisting: '/none',
    },
};

for (const [mode, expected] of Object.entries(wanted)) {
    const extra = await render(read(itemFiles[0]), mode);
    for (const [key, value] of Object.entries(extra)) { console.log(`${mode}.${key}=${value}`); }
    for (const [key, value] of Object.entries(expected)) {
        if (String(extra[key]) !== value) {
            raised.push(`${mode}.${key}`);
            console.error(`${mode}.${key}: expected '${value}', got '${extra[key]}'`);
            process.exitCode = 1;
        }
    }
}

console.log(`raised=${raised.length}`);
