import { createBackend } from './backend.js';
import { exportFile } from './export.js';
import { drawShell } from './shell.js';
import { translate, word } from './strings.js';

const view = document.querySelector('#demoView');
const loading = document.querySelector('#demoLoading');
const toast = document.querySelector('#demoToast');
const picker = document.querySelector('#demoCulture');
const load = window.fetch.bind(window);
let fading;

function say(message) {
    toast.textContent = message;
    toast.hidden = false;
    clearTimeout(fading);
    fading = setTimeout(() => { toast.hidden = true; }, 4000);
}

const [data, source] = await Promise.all([
    load('data.json').then((response) => response.json()),
    load(view.dataset.page).then((response) => response.text()),
]);
const backend = createBackend(data);

function request(method, target, body) {
    const [path, query] = String(target).split('?');
    return backend.request(method, path.replace(/^Inventory\//, ''),
        Object.fromEntries(new URLSearchParams(query)), body ? JSON.parse(body) : undefined);
}

window.ApiClient = {
    serverId: () => 'demo',
    accessToken: () => '',
    // The web client leaves out what has no value, and the page counts on that.
    getUrl: (path, params) => path + '?' + new URLSearchParams(Object.entries(params ?? {})
        .filter(([, value]) => value !== null && value !== undefined && value !== '')),
    getJSON: (target) => request('GET', target),
    ajax: (options) => request(options.type, options.url, options.data),
};

window.Dashboard = {
    showLoadingMsg() { loading.hidden = false; },
    hideLoadingMsg() { loading.hidden = true; },
    alert: say,
};

window.fetch = (target, options) => String(target).startsWith('Inventory/Export')
    ? request('GET', target).then((sheet) => new Response(exportFile(sheet), { headers: { 'Content-Disposition': `attachment; filename=${sheet.FileName}` } }))
    : load(target, options);

const cultures = Object.keys(data.Schemas);
for (const culture of cultures) {
    picker.add(new Option(new Intl.DisplayNames([culture], { type: 'language' }).of(culture), culture));
}

picker.value = navigator.languages.flatMap((tag) => [tag, tag.split('-')[0]]).find((tag) => cultures.includes(tag)) ?? 'en';
document.documentElement.lang = picker.value;
const name = () => data.Schemas[picker.value].Strings.Title;
drawShell(data.Server, name());

const parsed = new DOMParser().parseFromString(source, 'text/html').querySelector('#InventoryPage');
const code = parsed.querySelector('script').textContent;
parsed.querySelector('script').remove();
const page = view.appendChild(document.importNode(parsed, true));
// A script that arrives through the parser above does not run, so it is loaded as one of its own.
await new Promise((resolve) => {
    const script = document.createElement('script');
    script.src = URL.createObjectURL(new Blob([code], { type: 'text/javascript' }));
    script.onload = resolve;
    document.body.appendChild(script);
});
page.dispatchEvent(new Event('pageshow'));

picker.addEventListener('change', () => {
    page.dispatchEvent(new Event('viewhide'));
    document.documentElement.lang = picker.value;
    translate(name());
    toast.hidden = true;
    page.dispatchEvent(new Event('pageshow'));
});

// The web client opens another address of the page as a view of its own.
window.addEventListener('hashchange', () => {
    page.dispatchEvent(new Event('viewhide'));
    page.dispatchEvent(new Event('pageshow'));
});

// Inside another page the language is that page's to choose: it is told what there is, and answers with one.
if (window.parent !== window) {
    document.querySelector('.demoLanguage').remove();
    window.parent.postMessage({ languages: cultures, language: picker.value }, location.origin);
    window.addEventListener('message', (event) => {
        if (event.origin === location.origin && cultures.includes(event.data?.language)) {
            picker.value = event.data.language;
            picker.dispatchEvent(new Event('change'));
        }
    });
}

view.addEventListener('click', (event) => {
    if (event.target.closest('#invBody a')) {
        event.preventDefault();
        say(word('OpensItem'));
    }
});

document.querySelector('#demoDrawer').addEventListener('click', (event) => {
    if (event.target.closest('#demoDrawer ul > li:not([aria-current])')) { say(word('OnlyPage').replace('{0}', name())); }
});
document.querySelectorAll('.demoBar [data-icon="arrowBack"], .demoUser').forEach((node) => {
    node.addEventListener('click', () => say(word('OnlyPage').replace('{0}', name())));
});
