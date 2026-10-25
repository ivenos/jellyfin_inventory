#!/bin/sh
# Rebuilds the README screenshots from the sample library of the demo, so a change to the table can be shown
# without arranging one by hand.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BROWSER_IMAGE="${PLAYWRIGHT_IMAGE:-mcr.microsoft.com/playwright:v1.64.1-noble}"
# The image carries the browsers but not the library, and the two have to be the same release.
BROWSER_VERSION=$(printf '%s' "$BROWSER_IMAGE" | sed -n 's/.*:v\([0-9.]*\).*/\1/p')
trap 'docker rm -f "${CONTAINER:-}" >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT TERM
PORT="${PORT:-8093}"
CONTAINER="jellyfin_inventory-screenshots-$PORT"
INVENTORY_DEMO_DIR="$HOME/.cache/jellyfin_inventory-screenshots-$PORT"
. "$ROOT/demo/serve.sh"

echo "== shots =="
mkdir -p "$WORK/browser"
cat > "$WORK/browser/shots.mjs" <<'SHOTS'
import { readFileSync } from 'node:fs';
import { chromium } from 'playwright';

const BASE = 'http://localhost:8096';
const browser = await chromium.launch({ args: ['--no-sandbox'] });
// Wide enough for the whole column set and the toolbar on one line, and drawn at a density a reader can still zoom into.
const screen = { viewport: { width: 1580, height: 950 }, deviceScaleFactor: 1.4, locale: 'en-US' };
const page = await browser.newPage(screen);

await page.goto(BASE + '/web/index.html#/login', { waitUntil: 'domcontentloaded' });
await page.waitForSelector('input#txtManualName', { timeout: 60000 });
await page.fill('input#txtManualName', 'admin');
await page.fill('input#txtManualPassword', 'inventoryshots');
await page.locator('button:visible').first().click();
await page.waitForTimeout(6000);

// Jellyfin serves the embedded page from a cache a restart does not clear.
await page.evaluate(() => fetch('/web/ConfigurationPage?name=Inventory&cb=' + Date.now()));
await page.goto(BASE + '/web/index.html#/configurationpage?name=Inventory', { waitUntil: 'domcontentloaded' });
await page.waitForSelector('#invBody tr', { timeout: 60000 });
await page.waitForTimeout(2500);

if (await page.evaluate(() => document.querySelector('.invTools').getBoundingClientRect().top
    >= document.querySelector('.invTypes').getBoundingClientRect().bottom)) {
    console.log(`WARNING: the toolbar wraps at ${screen.viewport.width} px, the shots need a wider window`);
}

await page.click('.invType[data-type="Movie"]');
await page.waitForSelector('.invType[data-type="Movie"][aria-pressed="true"]:not([aria-busy])', { timeout: 30000 });
await page.waitForTimeout(1500);
await page.screenshot({ path: '/out/movies.png' });

await page.click('.invType[data-type="Series"]');
await page.waitForTimeout(2500);
await page.selectOption('#invExpand', '2');
await page.waitForSelector('#invBody tr[data-depth="2"]', { timeout: 60000 });
await page.waitForTimeout(1500);
await page.screenshot({ path: '/out/series.png' });

const look = (view, at) => view.evaluate((at) => {
    const place = (node) => [node.getBoundingClientRect().x, node.getBoundingClientRect().y];
    const drawer = document.querySelector(at.drawer);
    const read = (selector) => [...drawer.querySelectorAll(selector)]
        .map((node) => [node.textContent.trim(), ...place(node), getComputedStyle(node).fontSize]);
    return {
        menu: read(at.entry),
        sections: read(at.section),
        drawer: [drawer.getBoundingClientRect().width, getComputedStyle(drawer).backgroundColor],
        selected: [getComputedStyle(drawer.querySelector(at.selected)).backgroundColor],
        bar: [document.querySelector(at.bar).getBoundingClientRect().height],
        page: place(document.querySelector(at.page)),
    };
}, at);
const same = (a, b) => typeof a === 'number' ? Math.abs(a - b) <= 1
    : Array.isArray(a) ? a.length === b.length && a.every((value, at) => same(value, b[at])) : a === b;

const shell = await browser.newPage(screen);
await shell.route('http://demo.invalid/**', (route) => {
    const file = '/repo/demo/web' + new URL(route.request().url()).pathname;
    return file.endsWith('/index.html')
        ? route.fulfill({ contentType: 'text/html', body: readFileSync(file, 'utf8')
            .replace('src="demo.js">', '>import { drawShell } from "./shell.js"; drawShell({ Version: "" });') })
        : route.fulfill({ path: file });
});
await shell.goto('http://demo.invalid/index.html');
await shell.waitForSelector('#demoDrawer li');

try {
    const theirs = await look(page, { drawer: '.MuiDrawer-paper', entry: 'span.MuiListItemText-primary',
        section: '.MuiListSubheader-root', selected: '.Mui-selected', bar: 'header', page: '#InventoryPage' });
    const ours = await look(shell, { drawer: '#demoDrawer', entry: 'li span',
        section: 'h3', selected: '[aria-current]', bar: '.demoBar', page: '#demoView' });
    for (const part of Object.keys(theirs).filter((part) => !same(theirs[part], ours[part]))) {
        console.log(`WARNING: the dashboard of the demo differs from Jellyfin's in its ${part}`);
        console.log(`  Jellyfin: ${JSON.stringify(theirs[part])}\n  demo:     ${JSON.stringify(ours[part])}`);
    }
} catch (error) {
    console.log(`WARNING: the dashboard of the demo could not be held against Jellyfin's: ${error.message}`);
}

await browser.close();
SHOTS

docker run --rm --init --security-opt label=disable --user "$(id -u):$(id -g)" \
    --network "container:$CONTAINER" --ipc=host -e HOME=/tmp \
    -v "$WORK/browser:/b" -v "$ROOT/.github/assets:/out" -v "$ROOT:/repo:ro" -w /b "$BROWSER_IMAGE" sh -c \
    "set -e
     [ -f node_modules/.playwright-$BROWSER_VERSION ] || { rm -rf node_modules
       npm install --no-audit --no-fund --silent playwright@$BROWSER_VERSION
       touch node_modules/.playwright-$BROWSER_VERSION; }
     node /b/shots.mjs"

ls -l "$ROOT/.github/assets"
