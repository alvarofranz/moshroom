// Run via run-terminal-scroll-tests.sh. Uses the bundled terminal and production resync output.
// Playwright may be supplied by MOSHROOM_PLAYWRIGHT_MODULE; no app, host or credentials are used.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const { chromium, webkit } = await import(process.env.MOSHROOM_PLAYWRIGHT_MODULE || 'playwright');
const engine = process.env.MOSHROOM_BROWSER_ENGINE || 'chromium';
const resources = fileURLToPath(new URL('../Resources/', import.meta.url));
const fixtures = JSON.parse(await fs.readFile(process.argv[2], 'utf8'));
const browser = await (engine === 'webkit' ? webkit : chromium).launch({headless: true,
  ...(engine === 'chromium' && process.env.MOSHROOM_CHROMIUM_EXECUTABLE
    ? {executablePath: process.env.MOSHROOM_CHROMIUM_EXECUTABLE} : {})});
let assertions = 0;
const check = (condition, message) => { assert.ok(condition, message); assertions++; };
try {
  const page = await browser.newPage({viewport: {width: 1000, height: 650}});
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.route('https://moshroom.test/**', async route => {
    const name = new URL(route.request().url()).pathname.slice(1) || 'term.html';
    await route.fulfill({body: await fs.readFile(resources + name),
      contentType: name.endsWith('.js') ? 'application/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html'});
  });
  await page.addInitScript(() => {
    window.events = []; window.sent = [];
    window.webkit = {messageHandlers: {
      interOp: {postMessage(m) { events.push(m); if (m.op === 'sendString') sent.push(m.data.string); }},
      wkScroller: {postMessage(m) {
        events.push(m);
        if (m.op === 'scrollTo') setTimeout(() => t.scrollPort_.scroller_.reportScroll(m.x, m.y), 0);
      }},
    }};
  });
  async function start() {
    await page.goto('https://moshroom.test/term.html');
    await page.evaluate(() => {
      window.applyUserSettings = () => { term_set('font-family', 'Menlo'); term_set('font-size', 20); };
      term_init(false, true);
    });
    await page.waitForFunction(() => events.some(e => e.op === 'terminalReady'));
  }
  for (const fixture of fixtures) {
    await start();
    const result = await page.evaluate(f => {
      t.realizeSize_(80, 24);
      // Start as a TUI whose mode-off output was lost during the disconnect.
      term_write('\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[?25l\x1b[?7l\x1b[4h');
      if (f.path === 'alternate' || f.path === 'leave-alternate') term_write('\x1b[?1049h');
      term_write(f.bytes);
      const mode = events.filter(e => e.op === 'scrollmode').at(-1);
      sent = [];
      term_reportWheelEvent('wheel', 120, 100, 0, -60, 3);
      return {mode, sent, mouse: _moshroomMouseReportOn(), sgr: t.vt.mouseCoordinates === t.vt.MOUSE_COORDINATES_SGR,
              text: t.getRowsText(0, t.getRowCount()), cursor: t.options_.cursorVisible, wrap: t.options_.wraparound, insert: t.options_.insertMode,
              top: t.getRowsText(t.scrollbackRows_.length, t.scrollbackRows_.length + 1), cursorRow: t.screen_.cursorPosition.row};
    }, fixture);
    check(result.cursor === true && result.wrap === true && result.insert === false, `${fixture.name}: restore cursor, wrap and insert modes`);
    if (fixture.screenTop) check(result.top.trim() === fixture.screenTop && result.cursorRow === fixture.cursorRow, `${fixture.name}: written rows keep their places`);
    if (fixture.longHistory) check(result.text.includes(fixture.longHistory), `${fixture.name}: preserve the complete wrapped history line`);
    check(result.mouse === fixture.mouse, `${fixture.name}: restore current mouse mode`);
    check(result.mode.mouseReport === fixture.mouse, `${fixture.name}: native scroll owner agrees`);
    check(result.mode.bracketedPaste === false, `${fixture.name}: clear obsolete paste mode`);
    if (fixture.mouse) {
      check(result.sent.length === 3 && result.sent.every(s => s.startsWith('\x1b[')), `${fixture.name}: deliver three wheel reports`);
    } else {
      check(result.sent.length === 0, `${fixture.name}: reading up must not send input to a shell`);
    }
    if ('sgr' in fixture) check(result.sgr === fixture.sgr, `${fixture.name}: coordinate encoding`);
  }
  // Reading a primary-screen transcript after a reconnect must move real rows and stay put
  // when the next output arrives; the old mouse owner swallowed this upward gesture entirely.
  await start();
  const shell = fixtures.find(f => f.name === 'overlap-flag-0-cached-true');
  await page.evaluate(bytes => { term_write('\x1b[?1003h\x1b[?1006h'); term_write(bytes); }, shell.bytes);
  await page.waitForTimeout(100);
  const before = await page.evaluate(() => t.scrollPort_.getTopRowIndex());
  await page.evaluate(() => term_reportWheelEvent('wheel', 100, 100, 0, -100, 4));
  await page.waitForTimeout(100);
  const after = await page.evaluate(() => t.scrollPort_.getTopRowIndex());
  check(after === before - 4, 'Restored shell exposes four rows of local history');
  await page.evaluate(() => term_write('\r\nOUTPUT ARRIVING WHILE READING\r\n'));
  await page.waitForTimeout(100);
  check(await page.evaluate(() => t.scrollPort_.getTopRowIndex()) === after, 'Output preserves reading position');
  // A full-screen program can own a transcript without requesting mouse reporting. This is the
  // reported failure: no local history, no mouse listener, and the old implementation discarded Up.
  await start();
  const paging = await page.evaluate(() => {
    term_write('\x1b[?1049h');
    const run = (dy, allowed, count = 1) => term_reportWheelEvent('wheel', 100, 100, 0, dy, count, allowed);
    sent = []; run(-24, true);
    const up = sent.slice();
    for (let i = 0; i < 4; i++) run(-24, true);
    const shortSwipe = sent.slice();
    run(24, true);
    const reversed = sent.slice();
    term_beginScrollGesture(); run(-24, true);
    const nextGesture = sent.slice();
    sent = []; term_beginScrollGesture(); run(-24, false); run(24, false);
    const mosh = sent.slice();
    term_write('\x1b[?1049l');
    sent = []; term_beginScrollGesture(); run(-24, true); run(24, true);
    const shell = sent.slice();
    term_write('\x1b[?1049h\x1b[?1003h\x1b[?1006h');
    sent = []; term_beginScrollGesture(); run(-72, true, 3);
    return {up, shortSwipe, reversed, nextGesture, mosh, shell, mouse: sent.slice()};
  });
  check(JSON.stringify(paging.up) === JSON.stringify(['\x1b[5~']), 'Mouse-free alternate screen receives Page Up');
  check(paging.shortSwipe.length === 1, 'Small trackpad swipe does not race through pages');
  check(paging.reversed.at(-1) === '\x1b[6~', 'Reversing direction pages down immediately');
  check(paging.nextGesture.length === 3 && paging.nextGesture.at(-1) === '\x1b[5~', 'New gesture responds immediately');
  check(paging.mosh.length === 0, 'Bare mosh alternate screen receives no synthetic keys in either direction');
  check(paging.shell.length === 0, 'Normal shell receives no synthetic keys in either direction');
  check(paging.mouse.length === 3 && paging.mouse.every(s => s.startsWith('\x1b[<64;')), 'Mouse-capable TUI keeps wheel reports, not page keys');
  // Continuous motion and momentum share the same distance budget, including application-cursor mode.
  await start();
  const sustained = await page.evaluate(() => {
    term_write('\x1b[?1049h\x1b[?1h');
    const realNow = Date.now;
    let clock = 10000;
    Date.now = () => clock;
    try {
      sent = []; term_beginScrollGesture();
      const threshold = Math.max(3, Math.floor(t.scrollPort_.visibleRowCount / 2));
      const step = () => { clock += 16; term_reportWheelEvent('wheel', 100, 100, 0, -24, 1, true); };
      step();
      for (let i = 0; i < threshold - 1; i++) step();
      const beforeThreshold = sent.slice(); step();
      const atThreshold = sent.slice();
      for (let i = 0; i < threshold; i++) step();
      const momentum = sent.slice();
      clock += 301; step();
      return {beforeThreshold, atThreshold, momentum, afterIdle: sent.slice()};
    } finally { Date.now = realNow; }
  });
  check(sustained.beforeThreshold.length === 1, 'Continuous movement accumulates before paging again');
  check(sustained.atThreshold.length === 2, 'Half a viewport advances one more page');
  check(sustained.momentum.length === 3 && sustained.momentum.every(s => s === '\x1b[5~'), 'Momentum remains paced with application cursor keys enabled');
  check(sustained.afterIdle.length === 4, 'A wheel tick after idle responds immediately');
  check(errors.length === 0, `No renderer exceptions: ${errors.join('; ')}`);
  console.log(`Terminal scroll (${engine}): ${fixtures.length} reconnect fixtures; ${assertions} assertions passed`);
} finally { await browser.close(); }
