// Exercise selection through the bundled renderer; no hosts, credentials or remote sessions.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const { chromium, webkit } = await import(process.env.MOSHROOM_PLAYWRIGHT_MODULE || 'playwright');
const engine = process.env.MOSHROOM_BROWSER_ENGINE || 'webkit';
const resources = fileURLToPath(new URL('../Resources/', import.meta.url));
const browser = await (engine === 'webkit' ? webkit : chromium).launch({headless: true,
  ...(engine === 'chromium' && process.env.MOSHROOM_CHROMIUM_EXECUTABLE
    ? {executablePath: process.env.MOSHROOM_CHROMIUM_EXECUTABLE} : {})});
let assertions = 0;
const equal = (actual, expected, label) => { assert.equal(actual, expected, label); assertions++; };
try {
  const page = await browser.newPage({viewport: {width: 1000, height: 650}});
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.route('https://moshroom.test/**', async route => {
    const name = new URL(route.request().url()).pathname.slice(1) || 'term.html';
    await route.fulfill({body: await fs.readFile(resources + name),
      contentType: name.endsWith('.js') ? 'application/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html'});
  });
  await page.addInitScript(() => {
    window.events = [];
    window.webkit = {messageHandlers: {
      interOp: {postMessage(m) { events.push(m); }},
      wkScroller: {postMessage(m) {
        if (m.op === 'scrollTo') setTimeout(() => t.scrollPort_.scroller_.reportScroll(m.x, m.y), 0);
      }},
    }};
  });
  const fixtures = [
    {name: 'partial first and last rows with block rail', rows: ['▎ The right app needs', '▎ no reconfiguration.', '▎', '▎ Keep everyone connected.'], start: 2, end: 15,
      clean: 'The right app needs no reconfiguration. Keep everyone'},
    {name: 'two rows starting inside a word', rows: ['▎ first sentence', '▎ second sentence'], start: 5, end: 8, clean: 'st sentence second'},
    {name: 'selection includes every rail', rows: ['  ▎ one', '  ▎ two', '  ▎ three'], clean: 'one two three'},
    {name: 'partial right border', rows: ['│ one   │', '│ two   │', '│ three │'], start: 2, end: 7, clean: 'one two three'},
    {name: 'CJK and combining marks with fixed column borders', rows: ['│ 中é   │', '│ 文ab  │'], clean: '中é 文ab'},
    {name: 'blank lines in a frame', rows: ['▎ one', '', '▎', '▎ two'], clean: 'one two'},
    {name: 'box border lines', rows: ['┌──────┐', '│ one  │', '│ two  │', '└──────┘'], clean: 'one two'},
    {name: 'ordinary pipes and inline blocks', rows: ['printf "a | b ▎ c" | sort', 'echo done'], clean: 'printf "a | b ▎ c" | sort echo done'},
    {name: 'shell continuation operators', rows: ['| grep needle', '| sort'], clean: '| grep needle | sort'},
    {name: 'inconsistent border columns are content', rows: ['▎ first', '  ▎ second'], clean: '▎ first ▎ second'},
    {name: 'one bordered row mixed with prose', rows: ['a block follows', '▎ sample'], clean: 'a block follows ▎ sample'},
    {name: 'a single selected rail is literal', rows: ['▎ sample'], end: 1, clean: '▎'},
    {name: 'box art only is literal', rows: ['┌──┐', '└──┘'], clean: '┌──┐ └──┘'},
    {name: 'block rails only are literal', rows: ['▎', '▎'], clean: '▎ ▎'},
    {name: 'rectangle excludes the border', rows: ['▎ one rest', '▎ two rest'], start: 2, end: 5, rect: true, clean: 'one two'},
    {name: 'soft wrapped URL', rows: ['https://example.test/' + 'abcdefghij'.repeat(10)], clean: 'https://example.test/' + 'abcdefghij'.repeat(10)},
  ];
  for (const f of fixtures) {
    await page.goto('https://moshroom.test/term.html');
    await page.evaluate(() => {
      window.applyUserSettings = () => { term_set('font-family', 'Menlo'); term_set('font-size', 20); };
      term_init(false, true);
    });
    await page.waitForFunction(() => events.some(e => e.op === 'terminalReady'));
    await page.evaluate(rows => { t.realizeSize_(80, 24); term_write(rows.join('\r\n')); }, f.rows);
    await page.waitForTimeout(80);
    const actual = await page.evaluate(f => {
      const g = _mshGeom();
      const lastRow = t.scrollbackRows_.length + t.screen_.cursorPosition.row;
      const end = f.end ?? t.screen_.cursorPosition.column;
      const pt = (row, col) => [g.left + col * g.cw, g.originTop + (row + 0.5) * g.ch];
      term_selBegin(...pt(0, f.start || 0), {rect: !!f.rect});
      term_selExtendTo(...pt(lastRow, end));
      return {clean: term_selText({oneLine: true}), raw: term_selText({raw: true}), state: term_selGeometry().state};
    }, f);
    equal(actual.state, 'active', f.name + ': real selection');
    equal(actual.clean, f.clean, f.name + ': clean copy');
    const expectedRaw = f.rect ? f.rows.map(r => r.slice(f.start, f.end)).join('\n') :
      f.rows.map((r, i) => r.slice(i === 0 ? f.start || 0 : 0, i === f.rows.length - 1 ? f.end : undefined)).join('\n');
    equal(actual.raw, expectedRaw, f.name + ': raw copy preserves selected text');
    // A TUI repaint must not change what the user already selected for copying.
    await page.evaluate(() => term_write('\x1b[H\x1b[2Jreplacement screen'));
    await page.waitForTimeout(80);
    equal(await page.evaluate(() => term_selText({oneLine: true})), f.clean, f.name + ': copied snapshot survives repaint');
  }
  equal(errors.join('; '), '', 'renderer exceptions');
  console.log(`Terminal selection (${engine}): ${assertions} assertions passed`);
} finally { await browser.close(); }
