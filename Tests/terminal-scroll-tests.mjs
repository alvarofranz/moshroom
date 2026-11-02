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
              altScroll: !!t.scrollWheelArrowKeys_,
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
    if ('altScroll' in fixture) check(result.altScroll === fixture.altScroll, `${fixture.name}: restore alternate scroll mode`);
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
  // Pages are sent by DISTANCE (half a viewport for the first, a whole viewport for each further
  // one): the first row used to page at once, and a phone flick skipped whole screens.
  await start();
  const paging = await page.evaluate(() => {
    term_write('\x1b[?1049h');
    const page = Math.max(6, t.scrollPort_.visibleRowCount);
    const half = Math.max(3, Math.floor(page / 2));
    // true = the plain-SSH 'page' policy, false = mosh ('none'); 'arrows' = a tmux control-mode tab.
    const run = (dy, allowed, count = 1) => term_reportWheelEvent('wheel', 100, 100, 0, dy, count,
      allowed === true ? 'page' : allowed === false ? 'none' : allowed);
    const rows = (n, dy, allowed) => { for (let i = 0; i < n; i++) run(dy, allowed); };
    const first = _moshroomPagingFirstRows;
    sent = []; term_beginScrollGesture(); rows(first - 1, -24, true);
    const shortSwipe = sent.slice();
    run(-24, true);
    const up = sent.slice();
    rows(page - 1, -24, true);
    const oneViewport = sent.slice();
    run(-24, true);
    const twoViewports = sent.slice();
    sent = []; rows(first - 1, 24, true);
    const reversedShort = sent.slice();
    run(24, true);
    const reversed = sent.slice();
    sent = []; term_beginScrollGesture(); rows(first - 1, -24, true);
    const nextGesture = sent.slice();
    // The finger lifts: momentum may add ONE page, however far it carries.
    sent = []; term_beginScrollGesture(); rows(first, -24, true); term_endScrollGesture(); rows(page * 3, -24, true);
    const momentum = sent.slice();
    sent = []; term_beginScrollGesture(); rows(page, -24, false); rows(page, 24, false);
    const mosh = sent.slice();
    term_write('\x1b[?1049l');
    sent = []; term_beginScrollGesture(); rows(page, -24, true); rows(page, 24, true);
    const shell = sent.slice();
    term_write('\x1b[?1049h\x1b[?1003h\x1b[?1006h');
    sent = []; term_beginScrollGesture(); run(-72, true, 3);
    const mouse = sent.slice();
    // Alternate scroll (DECSET 1007, what Codex sets): the wheel becomes arrow keys, one per row,
    // both directions, encoded per DECCKM. Only on a permitted transport, only off the primary screen.
    term_write('\x1b[?1003l\x1b[?1006l\x1b[?1007h');
    sent = []; term_beginScrollGesture(); run(-72, true, 3); run(48, true, 2);
    const altScroll = sent.slice();
    term_write('\x1b[?1h');
    sent = []; term_beginScrollGesture(); run(-24, true, 1);
    const altScrollSS3 = sent.slice();
    term_write('\x1b[?1l');
    sent = []; term_beginScrollGesture(); rows(page, -24, false);
    const altScrollMosh = sent.slice();
    term_write('\x1b[?1049l');
    sent = []; term_beginScrollGesture(); rows(page, -24, true);
    const altScrollShell = sent.slice();
    term_write('\x1b[?1049h');
    term_sanitizeModes();
    term_write('\x1b[?1049h');
    sent = []; term_beginScrollGesture(); rows(_moshroomPagingFirstRows, -24, true);
    const afterSanitize = sent.slice();
    // A tmux control-mode tab: arrows in any alternate screen, 1007 or not (tmux cannot replay the
    // mode a running program set before the tab attached); the primary screen still gets nothing.
    sent = []; term_beginScrollGesture(); run(-48, 'arrows', 2); run(24, 'arrows', 1);
    const tmuxArrows = sent.slice();
    term_write('\x1b[?1003h\x1b[?1006h');
    sent = []; term_beginScrollGesture(); run(-24, 'arrows', 1);
    const tmuxMouse = sent.slice();
    term_write('\x1b[?1003l\x1b[?1006l\x1b[?1049l');
    sent = []; term_beginScrollGesture(); rows(page, -24, 'arrows'); rows(page, 24, 'arrows');
    const tmuxShell = sent.slice();
    return {shortSwipe, up, oneViewport, twoViewports, reversedShort, reversed, nextGesture, momentum, mosh, shell, mouse,
            altScroll, altScrollSS3, altScrollMosh, altScrollShell, afterSanitize, tmuxArrows, tmuxMouse, tmuxShell};
  });
  check(paging.shortSwipe.length === 0, 'A wobble of a row or two sends no page');
  check(JSON.stringify(paging.up) === JSON.stringify(['\x1b[5~']), 'Three rows of upward travel send one Page Up');
  check(paging.oneViewport.length === 1, 'A whole viewport of travel is still one page');
  check(paging.twoViewports.length === 2 && paging.twoViewports.every(s => s === '\x1b[5~'), 'Each further viewport sends one more page');
  check(paging.reversedShort.length === 0, 'Reversing direction starts a new page budget');
  check(paging.reversed.length === 1 && paging.reversed[0] === '\x1b[6~', 'Three rows the other way page down');
  check(paging.nextGesture.length === 0, 'A new drag starts over');
  check(paging.momentum.length === 2, 'Momentum after the finger lifts adds at most one page');
  check(paging.mosh.length === 0, 'Bare mosh alternate screen receives no synthetic keys in either direction');
  check(paging.shell.length === 0, 'Normal shell receives no synthetic keys in either direction');
  check(paging.mouse.length === 3 && paging.mouse.every(s => s.startsWith('\x1b[<64;')), 'Mouse-capable TUI keeps wheel reports, not page keys');
  check(JSON.stringify(paging.altScroll) === JSON.stringify(['\x1b[A\x1b[A\x1b[A', '\x1b[B\x1b[B']), 'Alternate scroll sends one arrow per row, both directions');
  check(JSON.stringify(paging.altScrollSS3) === JSON.stringify(['\x1bOA']), 'Alternate scroll arrows follow application cursor mode');
  check(paging.altScrollMosh.length === 0, 'Alternate scroll never sends arrows on an unpermitted transport');
  check(paging.altScrollShell.length === 0, 'Alternate scroll never sends arrows on the primary screen');
  check(JSON.stringify(paging.afterSanitize) === JSON.stringify(['\x1b[5~']), 'Sanitize clears alternate scroll, paging returns');
  check(JSON.stringify(paging.tmuxArrows) === JSON.stringify(['\x1b[A\x1b[A', '\x1b[B']), 'A tmux control-mode tab sends arrows in any alternate screen');
  check(paging.tmuxMouse.length === 1 && paging.tmuxMouse[0].startsWith('\x1b[<64;'), 'Mouse reporting still outranks arrows in a tmux tab');
  check(paging.tmuxShell.length === 0, 'A tmux tab sends no synthetic keys on the primary screen');
  // Continuous motion and momentum share the same distance budget, including application-cursor mode.
  await start();
  const sustained = await page.evaluate(() => {
    term_write('\x1b[?1049h\x1b[?1h');
    const realNow = Date.now;
    let clock = 10000;
    Date.now = () => clock;
    try {
      sent = []; term_beginScrollGesture();
      const page = Math.max(6, t.scrollPort_.visibleRowCount);
      const first = _moshroomPagingFirstRows;
      const step = () => { clock += 16; term_reportWheelEvent('wheel', 100, 100, 0, -24, 1, true); };
      for (let i = 0; i < first - 1; i++) step();
      const beforeThreshold = sent.slice(); step();
      const atThreshold = sent.slice();
      for (let i = 0; i < page - 1; i++) step();
      const beforeNext = sent.slice(); step();
      const momentum = sent.slice();
      // A slow drag pauses between rows without losing its budget; a long idle starts over.
      clock += 400; for (let i = 0; i < page; i++) step();
      const slowDrag = sent.slice();
      clock += 1001; for (let i = 0; i < first - 1; i++) step();
      const afterIdle = sent.slice();
      return {beforeThreshold, atThreshold, beforeNext, momentum, slowDrag, afterIdle};
    } finally { Date.now = realNow; }
  });
  check(sustained.beforeThreshold.length === 0, 'Continuous movement accumulates before the first page');
  check(sustained.atThreshold.length === 1, 'Three rows send the first page');
  check(sustained.beforeNext.length === 1, 'A further viewport is needed for the next page');
  check(sustained.momentum.length === 2 && sustained.momentum.every(s => s === '\x1b[5~'), 'Momentum remains paced with application cursor keys enabled');
  check(sustained.slowDrag.length === 3, 'A pause under a second keeps the gesture budget');
  check(sustained.afterIdle.length === 3, 'After a long idle the budget starts over');
  check(errors.length === 0, `No renderer exceptions: ${errors.join('; ')}`);
  console.log(`Terminal scroll (${engine}): ${fixtures.length} reconnect fixtures; ${assertions} assertions passed`);
} finally { await browser.close(); }
