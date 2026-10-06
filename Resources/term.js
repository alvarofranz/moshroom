'use strict';

hterm.defaultStorage = new lib.Storage.Memory();

window.fontSizeDetectionMethod = 'canvas';

function _postMessage(op, data) {
  window.webkit.messageHandlers.interOp.postMessage({op, data});
}

hterm.notify = function(params) {
  var def = (curr, fallback) => curr !== undefined ? curr : fallback;
  if (params === undefined || params === null) {
    params = {};
  }


  var title = def(params.title, window.document.title);
  if (!title)
    title = 'hterm';

  _postMessage('notify', {title, body: params.body})
}

hterm.Terminal.prototype.ringBell = function() {
  // Flash the cursor on BEL character
  this.cursorNode_.style.backgroundColor = this.scrollPort_.getForegroundColor();
    
  setTimeout(() => this.restyleCursor_(), 200);
  
  _postMessage('ring-bell', null);
};

hterm.Terminal.prototype.copyStringToClipboard = function(content) {
  if (this.prefs_.get('enable-clipboard-notice')) {
    setTimeout(this.showOverlay.bind(this, hterm.notifyCopyMessage, 500), 200);
  }

  _postMessage('copy', {content});
};

// The program set its window/terminal title via OSC 0/2 (opencode, ssh, vim, tmux…). Keep
// document.title in sync AND push it to native so the terminal tab renames itself live — relying
// on WKWebView.title alone is unreliable for JS-driven title changes.
hterm.Terminal.prototype.setWindowTitle = function(title) {
  window.document.title = title;
  _postMessage('setTitle', {title: title || ''});
};

// Links open on the DEVICE, never inside the web view: window.open is dead in a WKWebView, and
// a URL printed by a remote agent is for the user's browser. hterm's OSC 8 anchors bind this
// function to their click listeners at span-creation time (long after this line runs), so every
// hyperlink — anchor click or tap dispatch — funnels through the one native `openLink` path,
// which dedupes the overlapping routes.
hterm.openUrl = function(url) {
  _postMessage('openLink', {url});
};

// ---- Selection (both platforms) --------------------------------------------------------------
// Select-to-copy runs on hterm's ROW MODEL, never on a WebKit selection. The terminal is
// user-select:none everywhere (see onTerminalReady), so WebKit never owns a selection, never paints
// its own tint, and never loses one when hterm re-renders a row. Instead:
//
//   - A selection is two endpoints, each a (row record, column) pair in the active buffer. A row
//     record is the object hterm keeps per row; its index in `scrollbackRows_ ++ screen_.rowsArray`
//     is the absolute row. Records survive scrolling, trimming and scroll-region moves, so the
//     selection follows its text instead of a DOM node that React may replace at any frame.
//   - The highlight is painted by us from the cell grid (one flat rect per row run, never two rects
//     over one pixel), so it is ONE shade whatever is underneath.
//   - The text comes from the records: a wrapped row (hterm's overflow flag) joins the next with no
//     newline, so a long command or URL copies as the one line it is.
//   - Native (TerminalSelection.swift) owns the gestures, the handles, the copy pill and the
//     clipboard. It only ever sees web-view points and absolute rows: every call below returns the
//     geometry object synchronously, and page-side changes (output rewriting the rows, a trim, a
//     screen switch, a scroll) are posted as {op: 'selection'} on the wkScroller handler. Text never
//     travels until native asks for it (term_selText).
//
// Every read of hterm's private row shape (records `o`, `v`, `nodes`; nodes `txt`, `wcw`, `attrs`)
// goes through the few helpers right below, and _mshSelfTest checks that shape once the terminal is
// up: if a future hterm changes it, selection switches itself off with a log line rather than
// copying garbage.

var _mshSel = null;              // the live selection, see _mshNew
var _mshSelEnabled = false;      // set by _mshSelfTest
var _mshGeomSeq = 0;             // stamps every geometry, so native can drop a stale one
var _mshOverlay = null;          // the highlight layer
var _mshValidateQueued = false;
var _mshPostQueued = false;
var _mshLastPostKey = '';
var _mshSelColor = 'rgba(255,82,90,0.45)';
var _mshReanchorMinChars = 3;    // a re-anchor needs at least this much non-blank text to trust

// -- Row shape (the only place that knows hterm's field names) --

function _mshRowCount() {
  return t.getRowCount();
}

function _mshRowAt(R) {
  return R >= 0 && R < _mshRowCount() ? t.getRowNode(R) : null;
}

function _mshRowWraps(rec) {
  return !!(rec && rec.o);
}

// One entry per COLUMN: {s: what is drawn there, w: 1 or 2}. A wide character's second column is a
// continuation entry {s: '', w: 0}; zero-width code points (combining marks, variation selectors)
// join the character before them, so a grapheme is never split.
function _mshCells(rec) {
  var cells = [];
  var nodes = rec && rec.nodes;
  if (!nodes) {
    return cells;
  }
  for (var i = 0; i < nodes.length; i++) {
    var n = nodes[i];
    var txt = n.txt || '';
    if (!txt) {
      continue;
    }
    if (n.attrs && n.attrs.asciiNode) {
      for (var j = 0; j < txt.length; j++) {
        cells.push({s: txt[j], w: 1});
      }
      continue;
    }
    for (var k = 0; k < txt.length;) {
      var cp = txt.codePointAt(k);
      var ch = String.fromCodePoint(cp);
      k += ch.length;
      var w = lib.wc.charWidth(cp);
      if (w === 0 && cells.length) {
        var last = cells.length - 1;
        if (cells[last].w === 0 && last > 0) {
          last--;
        }
        cells[last].s += ch;
        continue;
      }
      if (w === 2) {
        cells.push({s: ch, w: 2});
        cells.push({s: '', w: 0});
      } else {
        cells.push({s: ch, w: 1});
      }
    }
  }
  return cells;
}

function _mshCellsText(cells, c0, c1) {
  var out = '';
  var end = Math.min(c1, cells.length);
  for (var c = Math.max(c0, 0); c < end; c++) {
    out += cells[c].s;
  }
  return out;
}

function _mshSelfTest() {
  try {
    var ok = typeof t.getRowNode === 'function' && typeof t.getRowCount === 'function' &&
      Array.isArray(t.scrollbackRows_) && t.screen_ && Array.isArray(t.screen_.rowsArray) &&
      t.screen_.rowsArray.length > 0 && lib && lib.wc && typeof lib.wc.charWidth === 'function' &&
      t.scrollPort_ && t.scrollPort_.rowNodes_ && t.scrollPort_.characterSize;
    if (ok) {
      var rec = t.screen_.rowsArray[0];
      ok = rec && 'o' in rec && 'v' in rec && Array.isArray(rec.nodes) && rec.nodes.length > 0 &&
        typeof rec.nodes[0].txt === 'string' && typeof rec.nodes[0].wcw === 'number' &&
        !!rec.nodes[0].attrs;
    }
    if (ok) {
      // The width model agrees with hterm's own on a wide character.
      ok = lib.wc.charWidth('中'.codePointAt(0)) === 2 && lib.wc.charWidth(0x61) === 1;
    }
    _mshSelEnabled = !!ok;
  } catch (e) {
    _mshSelEnabled = false;
  }
  if (!_mshSelEnabled) {
    _postMessage('log', {area: 'selection', message: 'row model self-test failed, selection disabled'});
  }
}

// -- Geometry (web-view points, the space the native gestures use) --

function _mshGeom() {
  var sp = t.scrollPort_;
  var ch = sp.characterSize.height;
  var cw = sp.characterSize.width;
  var view = sp.screen_.getBoundingClientRect();
  // The row container carries the sub-row transform, so its rect already includes the shift.
  var rows = sp.rowNodes_.getBoundingClientRect();
  var fold = sp.topFold_ ? sp.topFold_.offsetHeight : 0;
  var top = sp.getTopRowIndex();
  return {
    ch: ch,
    cw: cw,
    left: rows.left,
    originTop: rows.top + fold - top * ch,   // client y of absolute row 0
    top: top,
    visible: sp.visibleRowCount,
    cols: t.screenSize.width,
    view: view,
  };
}

// The absolute row under a client y, clamped to the buffer.
function _mshRowAtY(y, g) {
  var R = Math.floor((y - g.originTop) / g.ch);
  var count = _mshRowCount();
  return Math.max(0, Math.min(R, count - 1));
}

// The boundary between two cells nearest to x: what a drag or a handle moves. Never inside a wide
// character.
function _mshBoundaryAt(x, R, g) {
  var f = (x - g.left) / g.cw;
  var col = Math.max(0, Math.min(Math.round(f), g.cols));
  var cells = _mshCells(_mshRowAt(R));
  if (col < cells.length && cells[col].w === 0) {
    col = (f - (col - 1)) < ((col + 1) - f) ? col - 1 : col + 1;
  }
  return col;
}

// The cell under x (for word and URL lookups): its column, stepped back onto a wide character's
// first column.
function _mshCellAt(x, R, g) {
  var col = Math.max(0, Math.min(Math.floor((x - g.left) / g.cw), g.cols - 1));
  var cells = _mshCells(_mshRowAt(R));
  if (col > 0 && col < cells.length && cells[col].w === 0) {
    col--;
  }
  return col;
}

// -- Positions --

function _mshPos(R, col) {
  return {rec: _mshRowAt(R), col: col, R: R};
}

// Where a position's record is now. Records only move (scrolling, a trim, a scroll region); one that
// cannot be found was trimmed away or reused, and the caller drops what depended on it.
function _mshIndexOf(p) {
  if (!p || !p.rec) {
    return -1;
  }
  if (t.getRowNode(p.R) === p.rec) {
    return p.R;
  }
  var sb = t.scrollbackRows_;
  var i = t.screen_.rowsArray.indexOf(p.rec);
  if (i >= 0) {
    return (p.R = sb.length + i);
  }
  i = sb.indexOf(p.rec);
  return i >= 0 ? (p.R = i) : -1;
}

function _mshCmp(R1, c1, R2, c2) {
  return R1 !== R2 ? R1 - R2 : c1 - c2;
}

// -- Units: what one press selects at a given granularity --

// The logical line through row R: the rows hterm wrapped into one, as cells with their row and
// column, plus the joined string and each cell's offset in it.
function _mshLogicalLine(R) {
  var count = _mshRowCount();
  var first = R;
  while (first > 0 && R - first < 200 && _mshRowWraps(_mshRowAt(first - 1))) {
    first--;
  }
  var last = R;
  while (last < count - 1 && last - R < 200 && _mshRowWraps(_mshRowAt(last))) {
    last++;
  }
  var cells = [];
  var str = '';
  for (var r = first; r <= last; r++) {
    var rc = _mshCells(_mshRowAt(r));
    for (var c = 0; c < rc.length; c++) {
      if (rc[c].w === 0) {
        continue;
      }
      cells.push({s: rc[c].s, w: rc[c].w, R: r, col: c, off: str.length});
      str += rc[c].s;
    }
  }
  return {first: first, last: last, cells: cells, str: str};
}

function _mshLineCellIndex(line, R, col) {
  for (var i = 0; i < line.cells.length; i++) {
    var cell = line.cells[i];
    if (cell.R === R && col >= cell.col && col < cell.col + cell.w) {
      return i;
    }
  }
  return -1;
}

function _mshIsWordChar(s) {
  if (!s || /^\s+$/.test(s) || s === ' ') {
    return false;
  }
  var cp = s.codePointAt(0);
  if (cp >= 0x2500 && cp <= 0x257f) {
    return false;            // box drawing: TUI borders and gutters
  }
  return '"\'`()[]{}<>|'.indexOf(s[0]) < 0;
}

var _moshroomUrlRegex = /(?:[a-z][a-z0-9+.-]*:\/\/|www\.|mailto:)[^\s\[\](){}<>"'`]+/gi;

// A URL in the logical line that contains cell index `idx`: {from, to} cell indexes (to exclusive)
// and the cleaned URL, or null.
function _mshUrlInLine(line, idx) {
  if (idx < 0) {
    return null;
  }
  var off = line.cells[idx].off;
  _moshroomUrlRegex.lastIndex = 0;
  var m;
  while ((m = _moshroomUrlRegex.exec(line.str))) {
    if (off < m.index || off >= m.index + m[0].length) {
      continue;
    }
    // Trailing punctuation belongs to the prose, not the link.
    var url = m[0].replace(/[.,;:!?'")\]}>]+$/, '');
    var endOff = m.index + url.length;
    if (off >= endOff) {
      return null;
    }
    var from = idx, to = idx + 1;
    while (from > 0 && line.cells[from - 1].off >= m.index) {
      from--;
    }
    while (to < line.cells.length && line.cells[to].off < endOff) {
      to++;
    }
    return {from: from, to: to, url: url};
  }
  return null;
}

// The smart word under (R, col), as cell indexes in its logical line: a URL containing the point
// wins (even across wrapped rows); otherwise the run of characters that are not whitespace, quotes,
// brackets, pipes or box drawing, minus trailing sentence punctuation. So /srv/app/foo.swift:12,
// --flag=value and user@host come out whole.
function _mshWordAt(R, col) {
  var line = _mshLogicalLine(R);
  var idx = _mshLineCellIndex(line, R, col);
  if (idx < 0 || !_mshIsWordChar(line.cells[idx].s)) {
    return null;
  }
  var url = _mshUrlInLine(line, idx);
  if (url) {
    return {line: line, from: url.from, to: url.to};
  }
  var from = idx, to = idx + 1;
  while (from > 0 && _mshIsWordChar(line.cells[from - 1].s)) {
    from--;
  }
  while (to < line.cells.length && _mshIsWordChar(line.cells[to].s)) {
    to++;
  }
  while (to - 1 > idx && /^[.,;:!?]$/.test(line.cells[to - 1].s)) {
    to--;
  }
  return {line: line, from: from, to: to};
}

function _mshSpanFromLine(line, from, to) {
  var a = line.cells[from];
  var b = line.cells[to - 1];
  return {sR: a.R, sC: a.col, eR: b.R, eC: b.col + b.w};
}

// The whole logical line through R, without its surrounding blanks.
function _mshLineSpan(R) {
  var line = _mshLogicalLine(R);
  var from = 0, to = line.cells.length;
  while (from < to && !/\S/.test(line.cells[from].s)) {
    from++;
  }
  while (to > from && !/\S/.test(line.cells[to - 1].s)) {
    to--;
  }
  return from < to ? _mshSpanFromLine(line, from, to) : null;
}

// The unit at (x, y) for a granularity, as {sR, sC, eR, eC}. A word press on blank space falls back
// to the boundary there, which is what lets a word drag cross the gaps between words.
function _mshUnitAt(x, y, gran, g) {
  var R = _mshRowAtY(y, g);
  if (gran === 'word') {
    var w = _mshWordAt(R, _mshCellAt(x, R, g));
    if (w) {
      return _mshSpanFromLine(w.line, w.from, w.to);
    }
  } else if (gran === 'line') {
    var span = _mshLineSpan(R);
    if (span) {
      return span;
    }
    var line = _mshLogicalLine(R);
    return {sR: line.first, sC: 0, eR: line.first, eC: 0};
  }
  var col = _mshBoundaryAt(x, R, g);
  return {sR: R, sC: col, eR: R, eC: col};
}

// -- The selection --

function _mshNew(unit, gran, mode) {
  _mshSel = {
    primary: t.isPrimaryScreen(),
    cols: t.screenSize.width,
    mode: mode || 'linear',
    gran: gran,
    state: 'active',
    anc: {s: _mshPos(unit.sR, unit.sC), e: _mshPos(unit.eR, unit.eC)},
    s: _mshPos(unit.sR, unit.sC),
    e: _mshPos(unit.eR, unit.eC),
    snap: null,
    snapDirty: true,
  };
  return _mshSel;
}

// Moves the focus: the selection runs from the anchor unit to the focus unit, keeping the whole
// anchor unit selected whichever way the focus went (a word drag keeps its first word).
function _mshFocus(unit) {
  var sel = _mshSel;
  var aS = _mshIndexOf(sel.anc.s), aE = _mshIndexOf(sel.anc.e);
  if (aS < 0 || aE < 0) {
    return false;
  }
  if (sel.mode === 'rect') {
    var r0 = Math.min(aS, unit.sR), r1 = Math.max(aS, unit.sR);
    var c0 = Math.min(sel.anc.s.col, unit.sC), c1 = Math.max(sel.anc.s.col, unit.sC);
    sel.s = _mshPos(r0, c0);
    sel.e = _mshPos(r1, c1);
  } else if (_mshCmp(unit.sR, unit.sC, aS, sel.anc.s.col) < 0) {
    sel.s = _mshPos(unit.sR, unit.sC);
    sel.e = _mshPos(aE, sel.anc.e.col);
  } else {
    sel.s = _mshPos(aS, sel.anc.s.col);
    sel.e = _mshCmp(unit.eR, unit.eC, aE, sel.anc.e.col) > 0
      ? _mshPos(unit.eR, unit.eC)
      : _mshPos(aE, sel.anc.e.col);
  }
  sel.snapDirty = true;
  return true;
}

function _mshIsEmpty(sel) {
  if (!sel) {
    return true;
  }
  var sR = _mshIndexOf(sel.s), eR = _mshIndexOf(sel.e);
  if (sR < 0 || eR < 0) {
    return true;
  }
  if (sel.mode === 'rect') {
    return sel.s.col === sel.e.col;
  }
  return _mshCmp(sR, sel.s.col, eR, sel.e.col) >= 0;
}

// The selected columns of the i-th selected row (of n): [c0, c1).
function _mshRowRange(sel, i, n) {
  if (sel.mode === 'rect') {
    return [sel.s.col, sel.e.col];
  }
  return [i === 0 ? sel.s.col : 0, i === n - 1 ? sel.e.col : Infinity];
}

// The text of each selected row, kept so output that rewrites the rows can be detected, the
// selection re-found if the text only moved, and copied as the user saw it if it did not survive.
function _mshTakeSnapshot() {
  var sel = _mshSel;
  sel.snapDirty = false;
  sel.snap = null;
  var sR = _mshIndexOf(sel.s), eR = _mshIndexOf(sel.e);
  if (sR < 0 || eR < 0 || eR < sR) {
    return;
  }
  var n = eR - sR + 1;
  var snap = [];
  for (var i = 0; i < n; i++) {
    var rec = t.getRowNode(sR + i);
    var range = _mshRowRange(sel, i, n);
    snap.push({rec: rec, txt: _mshCellsText(_mshCells(rec), range[0], range[1]), o: _mshRowWraps(rec)});
  }
  sel.snap = snap;
}

function _mshSnapshotIfNeeded() {
  if (_mshSel && _mshSel.state === 'active' && _mshSel.snapDirty) {
    _mshTakeSnapshot();
  }
}

// -- Text --

var _mshGutterRegex = /^[─-╿|]$/;

// rows: [{txt, o}] in order. linear: a wrapped row joins the next with no newline and keeps its
// trailing blanks (the line continues there); any other row loses its trailing blanks (unless raw)
// and ends with a newline.
function _mshJoinRows(rows, mode, raw) {
  var out = '';
  for (var i = 0; i < rows.length; i++) {
    var txt = rows[i].txt;
    var last = i === rows.length - 1;
    if (mode !== 'rect' && rows[i].o && !last) {
      out += txt;
      continue;
    }
    out += raw ? txt : txt.replace(/\s+$/, '');
    if (!last) {
      out += '\n';
    }
  }
  return out;
}

// "One line": the selection as a single line, for pasting a wrapped command or a paragraph a TUI
// broke into rows. Rows join with one space (wrapped rows with none), runs of blanks collapse, and a
// box-drawing gutter that every row carries at the same column (a TUI's border, a diff's bar) is
// dropped on either side.
function _mshOneLine(rows) {
  // A row that is nothing but box drawing (a TUI's top or bottom border, a rule) carries no text.
  // (Unless that is all there is: then the user asked for exactly that.)
  var withText = rows.filter(function(r) {
    return /[^\s\u2500-\u257F]/.test(r.txt);
  });
  if (withText.length) {
    rows = withText;
  }
  var txts = [];
  var i;
  for (i = 0; i < rows.length; i++) {
    txts.push(rows[i].txt);
  }
  if (rows.length > 1) {
    txts = _mshStripGutter(txts, false);
    txts = _mshStripGutter(txts, true);
  }
  var out = '';
  for (i = 0; i < txts.length; i++) {
    out += txts[i];
    if (i < txts.length - 1 && !rows[i].o) {
      out += ' ';
    }
  }
  return out.replace(/\s+/g, ' ').trim();
}

function _mshStripGutter(txts, right) {
  var at = -1;
  for (var i = 0; i < txts.length; i++) {
    var s = txts[i];
    if (!/\S/.test(s)) {
      continue;
    }
    var k = right ? s.replace(/\s+$/, '').length - 1 : s.search(/\S/);
    if (!_mshGutterRegex.test(s[k]) || (at >= 0 && k !== at)) {
      return txts;
    }
    at = k;
  }
  if (at < 0) {
    return txts;
  }
  return txts.map(function(s) {
    if (!/\S/.test(s)) {
      return s;
    }
    return right ? s.slice(0, at) : s.slice(at + 1);
  });
}

// The selected rows as [{txt, o}]: live from the records, or the snapshot once the text is gone.
function _mshRowsForText(sel) {
  if (sel.state === 'clip') {
    return sel.snap || [];
  }
  _mshSnapshotIfNeeded();
  return sel.snap || [];
}

// -- Painting --

function _mshEnsureOverlay() {
  if (!_mshOverlay) {
    _mshOverlay = document.createElement('div');
    _mshOverlay.style.cssText =
      'position:fixed;overflow:hidden;pointer-events:none;z-index:2147483646;left:0;top:0;width:0;height:0;';
    (document.body || document.documentElement).appendChild(_mshOverlay);
  }
  return _mshOverlay;
}

// The selection's visible rects in client coordinates, at most one per row (consecutive full rows
// merged), so no pixel is ever covered twice and the red is one shade everywhere. Every row but the
// last of a linear selection runs to the end of the line, the convention of every terminal.
function _mshRects(sel, g) {
  var rects = [];
  var sR = _mshIndexOf(sel.s), eR = _mshIndexOf(sel.e);
  if (sR < 0 || eR < 0) {
    return rects;
  }
  var n = eR - sR + 1;
  var from = Math.max(sR, g.top - 1);
  var to = Math.min(eR, g.top + g.visible + 1);
  for (var R = from; R <= to; R++) {
    var range = _mshRowRange(sel, R - sR, n);
    var c0 = range[0];
    var c1 = sel.mode === 'linear' && R < eR ? g.cols : Math.min(range[1], g.cols);
    if (c1 <= c0) {
      continue;
    }
    var x = g.left + c0 * g.cw;
    var y = g.originTop + R * g.ch;
    var w = (c1 - c0) * g.cw;
    var prev = rects[rects.length - 1];
    if (prev && prev.x === x && prev.w === w && Math.abs(prev.y + prev.h - y) < 0.5) {
      prev.h += g.ch;
      continue;
    }
    rects.push({x: x, y: y, w: w, h: g.ch});
  }
  return rects;
}

function _mshPaint() {
  if (!_mshOverlay && !_mshSel) {
    return;
  }
  var ov = _mshEnsureOverlay();
  var sel = _mshSel;
  var rects = [];
  var g = null;
  if (sel && sel.state === 'active' && t && t.scrollPort_) {
    g = _mshGeom();
    rects = _mshRects(sel, g);
    var v = g.view;
    ov.style.left = v.left + 'px';
    ov.style.top = v.top + 'px';
    ov.style.width = v.width + 'px';
    ov.style.height = v.height + 'px';
  }
  while (ov.childNodes.length > rects.length) {
    ov.removeChild(ov.lastChild);
  }
  for (var i = 0; i < rects.length; i++) {
    var d = ov.childNodes[i];
    if (!d) {
      d = document.createElement('div');
      d.style.cssText = 'position:absolute;background:' + _mshSelColor + ';';
      ov.appendChild(d);
    }
    var r = rects[i];
    d.style.left = (r.x - g.view.left) + 'px';
    d.style.top = (r.y - g.view.top) + 'px';
    d.style.width = r.w + 'px';
    d.style.height = r.h + 'px';
  }
  _mshQueuePost();
}

// -- The geometry native reads --

function _mshGeometry(extra) {
  var sel = _mshSel;
  var out = {seq: ++_mshGeomSeq, state: 'none', enabled: _mshSelEnabled};
  if (extra) {
    for (var k in extra) {
      out[k] = extra[k];
    }
  }
  if (!sel || !t || !t.scrollPort_) {
    return out;
  }
  if (sel.state === 'clip') {
    out.state = 'clip';
    out.rows = sel.snap ? sel.snap.length : 0;
    return out;
  }
  if (_mshIsEmpty(sel)) {
    return out;
  }
  var g = _mshGeom();
  var sR = _mshIndexOf(sel.s), eR = _mshIndexOf(sel.e);
  var v = g.view;
  var point = function(R, col) {
    var y = g.originTop + R * g.ch;
    return {
      x: g.left + col * g.cw,
      y: y,
      h: g.ch,
      row: R,
      visible: y + g.ch * 0.5 >= v.top && y + g.ch * 0.5 <= v.bottom,
    };
  };
  var rects = _mshRects(sel, g);
  var bounds = null;
  for (var i = 0; i < rects.length; i++) {
    var r = rects[i];
    var x0 = Math.max(r.x, v.left), y0 = Math.max(r.y, v.top);
    var x1 = Math.min(r.x + r.w, v.right), y1 = Math.min(r.y + r.h, v.bottom);
    if (x1 <= x0 || y1 <= y0) {
      continue;
    }
    if (!bounds) {
      bounds = {x: x0, y: y0, x1: x1, y1: y1};
    } else {
      bounds.x = Math.min(bounds.x, x0);
      bounds.y = Math.min(bounds.y, y0);
      bounds.x1 = Math.max(bounds.x1, x1);
      bounds.y1 = Math.max(bounds.y1, y1);
    }
  }
  out.state = 'active';
  out.mode = sel.mode;
  out.gran = sel.gran;
  out.rows = eR - sR + 1;
  out.start = point(sR, sel.s.col);
  out.end = point(eR, sel.e.col);
  out.bounds = bounds ? {x: bounds.x, y: bounds.y, w: bounds.x1 - bounds.x, h: bounds.y1 - bounds.y} : null;
  out.view = {x: v.left, y: v.top, w: v.width, h: v.height};
  out.cell = {w: g.cw, h: g.ch};
  return out;
}

// Page-side changes reach native through here, at most once per frame and only when something it
// shows actually moved.
function _mshQueuePost() {
  if (_mshPostQueued) {
    return;
  }
  _mshPostQueued = true;
  requestAnimationFrame(_mshPostNow);
}

function _mshPostNow(reason) {
  _mshPostQueued = false;
  var handler = window.webkit && window.webkit.messageHandlers
    ? window.webkit.messageHandlers.wkScroller
    : null;
  if (!handler) {
    return;
  }
  var geo = _mshGeometry(typeof reason === 'string' ? {reason: reason} : null);
  var key = JSON.stringify([geo.state, geo.start, geo.end, geo.bounds, geo.rows, geo.view]);
  if (key === _mshLastPostKey && typeof reason !== 'string') {
    return;
  }
  _mshLastPostKey = key;
  geo.op = 'selection';
  handler.postMessage(geo);
}

function _mshClear(reason) {
  if (!_mshSel) {
    return;
  }
  _mshSel = null;
  _mshPaint();
  _mshPostNow(reason || 'cleared');
}

// -- Keeping it alive under output --

function _mshQueueValidate() {
  if (_mshValidateQueued) {
    return;
  }
  _mshValidateQueued = true;
  requestAnimationFrame(_mshValidate);
}

// Once per frame after output: the selected rows still hold the text they held, in order? Rows that
// only moved (scrolling, a trim, a scroll region) are found by record and nothing happens. A row that
// was rewritten is looked for nearby by content (mosh and tmux repaint whole regions, moving text
// with them); if it cannot be found the selection becomes a CLIP: the highlight goes, and Copy still
// gives the text the user selected.
function _mshValidate() {
  _mshValidateQueued = false;
  var sel = _mshSel;
  if (!sel || sel.state !== 'active') {
    return;
  }
  if (t.isPrimaryScreen() !== sel.primary) {
    _mshClear('screen');
    return;
  }
  if (sel.snapDirty || !sel.snap) {
    // Remade by the user since the last output: it describes the current text already.
    _mshTakeSnapshot();
    return;
  }
  var snap = sel.snap;
  var n = snap.length;
  var sbLen = t.scrollbackRows_.length;
  var screenRows = t.screen_.rowsArray;
  var onScreen = new Map();
  for (var i = 0; i < screenRows.length; i++) {
    onScreen.set(screenRows[i], sbLen + i);
  }
  var first = -1;
  var intact = true;
  for (i = 0; i < n; i++) {
    var row = snap[i];
    var idx = onScreen.get(row.rec);
    if (idx === undefined) {
      // Scrollback is never rewritten, only trimmed from the top.
      idx = (first >= 0 && t.scrollbackRows_[first + i] === row.rec) ? first + i : t.scrollbackRows_.indexOf(row.rec);
      if (idx < 0) {
        _mshClear('trimmed');
        return;
      }
    } else {
      var range = _mshRowRange(sel, i, n);
      if (_mshCellsText(_mshCells(row.rec), range[0], range[1]) !== row.txt) {
        intact = false;
        break;
      }
    }
    if (i === 0) {
      first = idx;
    } else if (idx !== first + i) {
      intact = false;
      break;
    }
  }
  if (intact) {
    sel.s.R = first;
    sel.e.R = first + n - 1;
    _mshPaint();
    return;
  }
  if (_mshReanchor(sel, first >= 0 ? first : _mshIndexOf(sel.s))) {
    _mshPaint();
    return;
  }
  sel.state = 'clip';
  _mshPaint();
  _mshPostNow('clip');
}

function _mshReanchor(sel, near) {
  var snap = sel.snap;
  var n = snap.length;
  var g = t.scrollPort_;
  var span = g.visibleRowCount;
  if (n > span * 2) {
    return false;
  }
  var chars = 0;
  for (var i = 0; i < n; i++) {
    chars += snap[i].txt.replace(/\s+/g, '').length;
  }
  if (chars < _mshReanchorMinChars) {
    return false;
  }
  if (!(near >= 0)) {
    near = Math.max(0, _mshRowCount() - span);
  }
  var count = _mshRowCount();
  var lo = Math.max(0, near - span), hi = Math.min(count - n, near + span);
  var found = -1;
  for (var k = lo; k <= hi; k++) {
    var match = true;
    for (i = 0; i < n && match; i++) {
      var range = _mshRowRange(sel, i, n);
      match = _mshCellsText(_mshCells(t.getRowNode(k + i)), range[0], range[1]) === snap[i].txt;
    }
    if (match) {
      if (found >= 0) {
        return false;        // ambiguous: two places hold the same text
      }
      found = k;
    }
  }
  if (found < 0) {
    return false;
  }
  sel.s = _mshPos(found, sel.s.col);
  sel.e = _mshPos(found + n - 1, sel.e.col);
  sel.anc = {s: _mshPos(found, sel.s.col), e: _mshPos(found + n - 1, sel.e.col)};
  for (i = 0; i < n; i++) {
    snap[i].rec = t.getRowNode(found + i);
  }
  return true;
}

// Called around every interpret: the snapshot must describe the rows BEFORE output touches them.
function _mshBeforeOutput() {
  _mshSnapshotIfNeeded();
}

function _mshAfterOutput() {
  _mshQueueValidate();
}

// -- The API native calls (each returns the geometry) --

function _mshReady() {
  return _mshSelEnabled && t && t.scrollPort_ && t.screen_;
}

function term_selWordAt(x, y) {
  return _mshUnitSelection(x, y, 'word');
}

function term_selLineAt(x, y) {
  return _mshUnitSelection(x, y, 'line');
}

function _mshUnitSelection(x, y, gran) {
  if (!_mshReady()) {
    return _mshGeometry();
  }
  var g = _mshGeom();
  var R = _mshRowAtY(y, g);
  var unit = null;
  if (gran === 'word') {
    var w = _mshWordAt(R, _mshCellAt(x, R, g));
    unit = w ? _mshSpanFromLine(w.line, w.from, w.to) : null;
  } else {
    unit = _mshLineSpan(R);
  }
  if (unit) {
    _mshNew(unit, gran, 'linear');
  } else {
    _mshSel = null;
  }
  _mshPaint();
  return _mshGeometry();
}

// A press that starts a drag. opts: {rect, extend, gran}. extend (shift-click) keeps the anchor of
// the selection there is and moves its focus here.
function term_selBegin(x, y, opts) {
  opts = opts || {};
  if (!_mshReady()) {
    return _mshGeometry();
  }
  var g = _mshGeom();
  if (opts.extend && _mshSel && _mshSel.state === 'active' && _mshSel.mode === 'linear') {
    if (_mshFocus(_mshUnitAt(x, y, _mshSel.gran, g))) {
      _mshPaint();
      return _mshGeometry();
    }
  }
  var gran = opts.gran || 'char';
  var unit = _mshUnitAt(x, y, opts.rect ? 'char' : gran, g);
  _mshNew(unit, opts.rect ? 'char' : gran, opts.rect ? 'rect' : 'linear');
  _mshPaint();
  return _mshGeometry();
}

function term_selExtendTo(x, y) {
  if (!_mshReady() || !_mshSel || _mshSel.state !== 'active') {
    return _mshGeometry();
  }
  var g = _mshGeom();
  if (_mshFocus(_mshUnitAt(x, y, _mshSel.mode === 'rect' ? 'char' : _mshSel.gran, g))) {
    _mshPaint();
  }
  return _mshGeometry();
}

// A handle moved one endpoint. If it crosses the other the two swap, and the result says so
// (`swapped`), so native can keep dragging the right handle.
function term_selMoveHandle(which, x, y) {
  if (!_mshReady() || !_mshSel || _mshSel.state !== 'active') {
    return _mshGeometry();
  }
  var sel = _mshSel;
  var g = _mshGeom();
  var R = _mshRowAtY(y, g);
  var col = _mshBoundaryAt(x, R, g);
  var sR = _mshIndexOf(sel.s), eR = _mshIndexOf(sel.e);
  var swapped = false;
  if (sel.mode === 'rect') {
    if (which === 'start') {
      sel.s = _mshPos(Math.min(R, eR), Math.min(col, sel.e.col));
      sel.e = _mshPos(Math.max(R, eR), Math.max(col, sel.e.col));
      swapped = R > eR || col > sel.e.col;
    } else {
      sel.e = _mshPos(Math.max(R, sR), Math.max(col, sel.s.col));
      sel.s = _mshPos(Math.min(R, sR), Math.min(col, sel.s.col));
      swapped = R < sR || col < sel.s.col;
    }
  } else if (which === 'start') {
    if (_mshCmp(R, col, eR, sel.e.col) >= 0) {
      sel.s = _mshPos(eR, sel.e.col);
      sel.e = _mshPos(R, col);
      swapped = true;
    } else {
      sel.s = _mshPos(R, col);
    }
  } else {
    if (_mshCmp(R, col, sR, sel.s.col) <= 0) {
      sel.e = _mshPos(sR, sel.s.col);
      sel.s = _mshPos(R, col);
      swapped = true;
    } else {
      sel.e = _mshPos(R, col);
    }
  }
  sel.gran = 'char';
  sel.anc = {s: _mshPos(_mshIndexOf(sel.s), sel.s.col), e: _mshPos(_mshIndexOf(sel.e), sel.e.col)};
  sel.snapDirty = true;
  _mshPaint();
  return _mshGeometry({swapped: swapped});
}

// Auto-scroll while a drag or a handle sits at the top or bottom edge: scroll the LOCAL buffer by
// `rows` (negative = up; this never sends anything to the remote), then re-apply the drag at the
// point. `what` is 'focus' (a drag), or 'start' / 'end' (a handle).
function term_selAutoScroll(rows, x, y, what) {
  if (!_mshReady()) {
    return _mshGeometry();
  }
  var sp = t.scrollPort_;
  var top = sp.getTopRowIndex();
  var max = Math.max(0, _mshRowCount() - sp.visibleRowCount);
  var next = Math.max(0, Math.min(top + (rows | 0), max));
  if (next !== top) {
    sp.scrollRowToTop(next);
  }
  if (!_mshSel || _mshSel.state !== 'active') {
    return _mshGeometry();
  }
  // A pointer past the edge selects up to the first (or last) VISIBLE row, never rows the
  // scroll has not shown yet.
  var view = sp.getScreenHeight();
  if (view > 2) {
    y = Math.max(1, Math.min(y, view - 1));
  }
  if (what === 'start' || what === 'end') {
    return term_selMoveHandle(what, x, y);
  }
  return term_selExtendTo(x, y);
}

function term_selClear(reason) {
  if (_mshSel) {
    _mshSel = null;
    _mshPaint();
  }
  return _mshGeometry({reason: reason || 'cleared'});
}

// opts: {raw, oneLine}. The selection's text, or '' when there is none.
function term_selText(opts) {
  opts = opts || {};
  var sel = _mshSel;
  if (!sel || (sel.state === 'active' && _mshIsEmpty(sel))) {
    return '';
  }
  var rows = _mshRowsForText(sel);
  if (opts.oneLine) {
    return _mshOneLine(rows);
  }
  return _mshJoinRows(rows, sel.mode, !!opts.raw);
}

function term_selGeometry() {
  return _mshGeometry();
}

// Repaint on any viewport change: our scroll path produces no DOM scroll event.
window.addEventListener('resize', function() {
  if (_mshSel) {
    _mshPaint();
  }
});

hterm.Terminal.IO.prototype.sendString = function(string) {
  _postMessage('sendString', {string});
};

hterm.msg = function() {}; // TODO: show messages

function _colorComponents(colorStr) {
  if (!colorStr) {
    return [0, 0, 0]; // Default is black
  }

  return colorStr
    .replace(/[^0-9,]/g, '')
    .split(',')
    .map(s => parseInt(s));
}

// Before we fully load hterm. We set options here.
var _prefs = new hterm.PreferenceManager('moshroom');
var t = {prefs_: _prefs}; // <- `t` will become actual hterm instance after decorate.

function term_set(key, value) {
  _prefs.set(key, value);
}

function term_get(key) {
  return _prefs.get(key);
}

function term_setupDefaults() {
  term_set('copy-on-select', false);
  term_set('audible-bell-sound', '');
  term_set('receive-encoding', 'raw'); // we are UTF8
  term_set('allow-images-inline', true); // need to make it work
  // hterm's own alternate-screen arrow emulation stays OFF: it fired one arrow per wheel tick with
  // no idea whether anything else could have handled the swipe, which at a shell prompt inside
  // tmux/mosh cycled the shell history under the user's finger and leaked literal "[A"/"[B" when
  // tmux's escape-time split the sequence. Moshroom's own ladder replaces it (see "Scrolling"
  // below): mouse reports first, then the alternate screen's local history, and a Down key (never
  // an Up) as the last resort, one write per gesture.
  term_set('scroll-wheel-may-send-arrow-keys', false);
  // A gentle bump to the client-side scrollback scroll speed (hterm's own pixel-delta wheel path,
  // the instant local scroll on the normal screen). Default is 1; 2 is noticeably less sluggish
  // without running away. Kept modest on purpose. Does not touch the alt-screen TUI mouse-report
  // path (that scroll lives on the remote, over the network).
  term_set('scroll-wheel-move-multiplier', 2);
}

function term_processKB(str) {
  if (!t.prompt) {
    return;
  }
  if (str) {
    t.prompt.processInput(str);
  }
}

function term_displayInput(str, display) {
  if (!t || !t.accessibilityReader_) {
    return;
  }
  
  t.accessibilityReader_.hasUserGesture = true;
  
  if (!display) {
    return;
  }
  
  if (str && !t.prompt._secure) {
    window.KeystrokeVisualizer.processInput(str);
  }
}


function term_setup(accessibilityEnabled) {
  t = new hterm.Terminal('moshroom');

  t.onTerminalReady = function() {
    window.installKB(t, t.scrollPort_.screen_);
    term_setAutoCarriageReturn(true);
    // Apps/agents can copy to the iOS clipboard via OSC 52, but NOT from the first frames of a page:
    // a session restored or repainted into it replays the remote's last copy, which would overwrite
    // what the user copied since. Native turns it on once the session has settled (TermController).
    term_setClipboardWrite(false);

    t.setCursorVisible(true);
    // No terminal cursor block at the prompt — you type in Moshkitor, not here. Make hterm's
    // cursor transparent so the stray blue rectangle is gone. (The contentEditable insertion caret
    // is killed at the root by -webkit-user-modify:read-only below — the terminal is display-only.)
    t.setCursorColor('rgba(0, 0, 0, 0)');

    // The terminal is a READ-ONLY display that WebKit never selects in: you never type into it
    // (special keys go straight through TermDevice; any text is composed in Moshkitor), and
    // select-to-copy is Moshroom's own, on the row model (see "Selection" above). hterm marks its
    // <x-screen> contentEditable, so iOS WebKit would focus it on tap and paint an insertion caret
    // (caret-color:transparent is NOT honored for that tap-positioned caret on iOS):
    // -webkit-user-modify:read-only makes it no editing host at all. user-select:none on BOTH
    // platforms keeps WebKit from ever owning a selection: its own selection painting, its tint and
    // its handles are what made the old highlight come and go in two shades, and a WebKit range
    // collapsed whenever hterm re-rendered the rows under it.
    var _moshroomNoSelect = '*{-webkit-user-select:none!important;-webkit-user-modify:read-only!important;' +
      '-webkit-touch-callout:none!important;caret-color:transparent!important;}' +
      '::selection{background-color:transparent!important;}';
    var _moshroomScreen = t.scrollPort_.screen_;
    if (_moshroomScreen) {
      var _moshroomDoc = _moshroomScreen.ownerDocument;
      var _moshroomStyle = _moshroomDoc.createElement('style');
      _moshroomStyle.textContent = _moshroomNoSelect;
      (_moshroomDoc.head || _moshroomDoc.documentElement).appendChild(_moshroomStyle);
    }
    var _moshroomCaretStyle = document.createElement('style');
    _moshroomCaretStyle.textContent = _moshroomNoSelect;
    (document.head || document.documentElement).appendChild(_moshroomCaretStyle);
    document.body.style.caretColor = 'transparent';

    t.io.onTerminalResize = function(cols, rows) {
      // hterm does not reflow: a new width re-cuts every row, so a selection made on the old one
      // would describe columns that no longer hold its text.
      if (_mshSel && _mshSel.cols !== cols) {
        _mshClear('resize');
      }
      _postMessage('sigwinch', {cols, rows});
      if (t.prompt) {
        t.prompt.resize();
      }
    };

    var size = {
      cols: t.screenSize.width,
      rows: t.screenSize.height,
    };
    
    document.body.style.backgroundColor =
      t.scrollPort_.screen_.style.backgroundColor;
    // Paint the root <html> element too (not just <body>): during a fast TUI scroll WebKit can
    // briefly expose the root element / not-yet-painted tiles, and if only <body> is coloured
    // that shows through as a pure-black strip at the top. Colouring both kills it.
    document.documentElement.style.backgroundColor =
      t.scrollPort_.screen_.style.backgroundColor;
    var bgColor = _colorComponents(t.scrollPort_.screen_.style.backgroundColor);
    
    t.keyboard.characterEncoding = 'raw'; // we are UTF8: hterm must not re-encode what it sends
    t.uninstallKeyboard();
    // Belt to the braces of the same call in the appearance command list: a theme is user-supplied JS
    // and can throw halfway (term_init catches that and carries on), and this must hold regardless.
    _moshroomBlendPaletteBlack();
    
    _mshSelfTest();
    _postMessage('terminalReady', {size, bgColor});

    // Tell the native side who can use a swipe from the very first frame (normal screen, nothing
    // asking for the mouse), so it never has to assume. Every mode change re-posts it after this,
    // and on a jettison recovery this reload is what re-syncs it.
    _moshroomPostScrollMode();

    if (window.KeystrokeVisualizer) {
      window.KeystrokeVisualizer.enable();
    }
    t.setAccessibilityEnabled(accessibilityEnabled);
  };

  t.decorate(document.getElementById('terminal'));
}

function term_init(accessibilityEnabled, lockdownMode) {
  term_setupDefaults();
  try {
    applyUserSettings();
    //    var bgColor = term_get('background-color');
    //    document.body.style.backgroundColor = bgColor;
    //    document.body.parentNode.style.backgroundColor = bgColor;
    if (lockdownMode) {
      term_setup(accessibilityEnabled);
    } else {
      waitForFontFamily(term_setup);
    }
  } catch (e) {
    _postMessage('alert', {
      title: 'Error',
      message:
        'Failed to setup theme. Please check syntax of your theme.\n' +
        e.toString(),
    });
    term_setup(accessibilityEnabled);
  }
}

var _requestId = 0;
var _requestsMap = {};

class ApiRequest {
  constructor(name, request) {
    this.id = _requestId++;
    request.id = this.id;
    var self = this;
    this.promise = new Promise(function(resolve, reject) {
        self.resolve = resolve;
        self.reject = reject;
    });
    _requestsMap[this.id] = self
    _postMessage("api", {name, request: JSON.stringify(request)} );
    
    this.then = this.promise.then.bind(this.promise);
    this.catch = this.promise.catch.bind(this.promise);
  }
  
  cancel() {
    this.resolve(null);
    delete _requestsMap[this.id];
  }
}

function term_apiRequest(name, request) {
  return new ApiRequest(name, request)
}

function term_apiResponse(name, response) {
  var res = JSON.parse(response);
  var req = _requestsMap[res.requestId];
  if (!req) {
    return;
  }
  delete _requestsMap[req.id];
  req.resolve(res)
}


window.term_apiRequest = term_apiRequest;
window.term_apiResponse = term_apiResponse;

function term_write(data) {
  if (_mshSel) {
    _mshBeforeOutput();
  }
  t.interpret(data);
  if (_mshSel) {
    _mshAfterOutput();
  }
}

// Moshroom: whether any row on screen shows text. Native asks this to decide whether a terminal it
// is bringing back is still blank (it shows a loader only then, and only until this turns true).
function term_screenHasContent() {
  try {
    // The rows in view, through hterm's own text reader (rows are records here, not plain nodes).
    var top = t.scrollPort_.getTopRowIndex();
    var end = Math.min(top + t.screenSize.height, t.getRowCount());
    return /\S/.test(t.getRowsText(top, end));
  } catch (e) {
    // Cannot tell: say "has content", so a loader can never sit over a terminal it failed to read.
    return true;
  }
}

function term_paste(str) {
  t.onPaste_({text: str || ''});
}

var _utf8TextDecoder = new TextDecoder('utf8');
function term_write_b64(b64str) {
  var bytes = base64js.toByteArray(b64str);
  var data = _utf8TextDecoder.decode(bytes);
  term_write(data);
};

// Back at the local moshroom> prompt after a child command (ssh/mosh) returned: whatever modes
// the dead session latched must not outlive it. A mosh killed mid-"Connecting..." (or any TUI
// that never restored the screen) leaves the alternate screen, a hidden cursor or mouse
// reporting armed, and with them a prompt where swipes feed a phantom TUI and taps miss the
// composer. Display state only, idempotent; after a clean exit this is a no-op.
function term_sanitizeModes() {
  if (!t || !t.vt || !t.screen_) {
    return;
  }
  if (!t.isPrimaryScreen()) {
    t.setAlternateMode(false);
  }
  t.setCursorVisible(true);
  t.vt.mouseReport = t.vt.MOUSE_REPORT_DISABLED;
  t.setVTScrollRegion(null, null);
  t.setWraparound(true);
  // The pen too: a child that died mid-output with SGR attributes latched (reverse video, a
  // background color) must not paint the local prompt with them.
  t.primaryScreen_.textAttributes.reset();
  // Cursor-key mode too: a pager killed mid-session leaves it on, and the local prompt reads the
  // arrows the normal (CSI) way.
  if (t.keyboard) {
    t.keyboard.applicationCursor = false;
  }
  _moshroomPostScrollMode();
}

// The user just SENT something (a composed line, a quick key, a control byte, a paste). A terminal
// you are typing into has to show you the answer: if the viewport is parked up in the scrollback,
// snap it back to the live end. hterm's own `scroll-on-keystroke` never fires here because Moshroom
// types through TermDevice, not hterm's keyboard (which is uninstalled) — so this is that standard
// behaviour, wired to OUR input path. Output alone deliberately does NOT scroll: reading history
// while a command chatters on below is the whole point of a scrollback.
function term_scrollToBottom() {
  if (!t || !t.scrollPort_ || t.scrollPort_.isScrolledEnd) {
    return;
  }
  t.scrollEnd();
}

function _setTermCoordinates(event, x, y) {
  // One based row/column stored on the mouse event.
  var ty = (y / t.scrollPort_.characterSize.height | 0) + 1;
  var tx = (x / t.scrollPort_.characterSize.width | 0) + 1;
  event.terminalRow = ty;
  event.terminalColumn = tx;
}

// ---- Scrolling -------------------------------------------------------------------------------
// A swipe the local scrollback cannot serve (see _localScrollWins on the native side: the remote
// asked for the mouse, or the alternate screen is showing, or there is simply nothing banked to move)
// walks a ladder, and every rung of it is decided here, because only the page knows what the remote
// asked for and what the local buffers hold:
//
//   1. mouse reporting ON  -> the REMOTE owns the gesture: one standard wheel report per row of
//      finger movement (tmux with `mouse on`, opencode, vim `mouse=a`).
//   2. text above the viewport -> scroll the local history. hterm keeps a SEPARATE scrollback per
//      screen, and a full-screen program that SCROLLS (a pager walking down a file) banks its lines
//      into whichever one it is on, so that history is real; it was simply unreachable, because the
//      gesture was hard-wired to wheel reports nothing was listening for.
//   3. nothing local to move -> one cursor key per row, DOWNWARDS ONLY, which is the safe half of
//      what desktop terminals call alternate scroll: a pager that repaints in place pages forward
//      on Down, an editor moves its cursor down, and at a shell prompt Down is readline's
//      next-history, which does nothing when no history is being walked. Unconditional, and it needs
//      no user setting: the half that could hurt is the one that is never sent (see below), so the
//      only alternative to this rung is a swipe that does nothing at all.
//
// The direction asymmetry is the whole design, and it is measured, not cautious: Up at a shell
// prompt is previous-history, which is what made 1.0.4 unbearable (a swipe to read back typed the
// last command onto the prompt). Nothing needs Up either, because a program that scrolled has its
// lines in the local bank (rung 2 shows exactly the content the user is reaching for) and a program
// that did not has nothing above its first screen to show. So Up is never sent, in any state.
//
// Before all this, "alternate screen" alone armed the remote path, so a swipe in any full-screen
// program that had not asked for the mouse produced literally nothing: no report to send, no local
// scroll attempted. That is the whole "sometimes scrolling does nothing" class of bug.
//
// Measured on the live demo host (2026-08-17), because the ladder's shape follows from it: `less`
// answers to SS3 (\x1bOB) and ignores CSI (\x1b[B) once it sets DECCKM, and it DOES bank the lines
// that scroll off it (18 -> 21 scrollback rows for 3 lines). A mosh session banks nothing at all
// (120 lines of output, scrollback still 0): mosh repaints frames rather than scrolling, which is
// why it has no scrollback anywhere and why tmux (with `mouse on`, so rung 1) is the answer there.
// How far above the viewport to look for text before offering a local scroll. A window, not the row
// about to be revealed: blank lines inside real history must not stall the scroll, while the run of
// blank rows that entering the alternate screen leaves behind must not be walked into. Bounded
// because this runs per gesture tick.
var _moshroomHistoryScanRows = 40;

function _moshroomMouseReportOn() {
  return !!(t && t.vt && !t.defeatMouseReports_ &&
            t.vt.mouseReport !== t.vt.MOUSE_REPORT_DISABLED);
}

// Only these DEC modes change who can use a swipe, plus cursor-key mode (1, DECCKM), which decides
// how the native arrow keys are encoded. Deliberately NOT every mode: a TUI toggles cursor visibility
// (25) twice per frame, and posting on that would be a message storm.
var _moshroomScrollModeCodes = {
  '1': 1, '9': 1, '47': 1, '1000': 1, '1002': 1, '1003': 1,
  '1005': 1, '1006': 1, '1015': 1, '1047': 1, '1049': 1,
};

// The native side arms ONE of two scroll views before the gesture starts, and it cannot work out on
// its own whether the remote is listening for the wheel: only the page knows. So every change is
// pushed. This is not a nicety: an agent TUI that renders INLINE (no alternate screen) with mouse
// reporting on used to get nothing at all, because "normal screen" armed the local scrollback and an
// inline TUI leaves it empty, so the swipe died with nothing to move and no report sent.
function _moshroomPostScrollMode() {
  var handler = window.webkit && window.webkit.messageHandlers
    ? window.webkit.messageHandlers.wkScroller
    : null;
  if (!handler || !t || !t.vt || typeof t.isPrimaryScreen !== 'function') {
    return;
  }
  handler.postMessage({
    op: 'scrollmode',
    isPrimary: t.isPrimaryScreen(),
    mouseReport: _moshroomMouseReportOn(),
    // Cursor-key mode rides along: the quick-key and hardware arrows are encoded natively, and like
    // every terminal they must send SS3 (ESC O A) while the program asked for application cursor
    // keys and CSI (ESC [ A) otherwise. `less` ignores CSI arrows once it sets this mode.
    appCursor: !!(t.keyboard && t.keyboard.applicationCursor),
  });
}

var _moshroomBaseSetDECMode = hterm.VT.prototype.setDECMode;
hterm.VT.prototype.setDECMode = function(code, state) {
  _moshroomBaseSetDECMode.call(this, code, state);
  if (_moshroomScrollModeCodes['' + code]) {
    _moshroomPostScrollMode();
  }
};

var _moshroomBaseSetAlternateMode = hterm.Terminal.prototype.setAlternateMode;
hterm.Terminal.prototype.setAlternateMode = function(state) {
  var wasPrimary = typeof this.isPrimaryScreen === 'function' ? this.isPrimaryScreen() : true;
  _moshroomBaseSetAlternateMode.call(this, state);
  // The other screen holds other rows: a selection never follows the user across.
  if (_mshSel && wasPrimary !== this.isPrimaryScreen()) {
    _mshClear('screen');
  }
  _moshroomPostScrollMode();
};

var _moshroomBaseVTReset = hterm.VT.prototype.reset;
hterm.VT.prototype.reset = function() {
  _moshroomBaseVTReset.call(this);
  _mshClear('reset');
  _moshroomPostScrollMode();
};

// The scrollback TRIM moves the ground under the reader: hterm splices a block of rows off the TOP
// once the scrollback passes its limit, every remaining row shifts up by that many, and NEITHER side's
// scroll position knows it. hterm keeps its pixel offset, which now points that far further down and
// reads as "at the live end", so the next output line scrolls the reader away; the native scroll view
// can only clamp the offset back into range, and for a block that size the clamp IS the live end. So
// follow the content: measure the drop by where a row that SURVIVED it ended up (no hardcoded copy of
// hterm's limit) and move the viewport by exactly that much. Only while reading back, because at the
// live end the right place to be is still the live end.
var _moshroomBaseAppendRows = hterm.Terminal.prototype.appendRows_;
hterm.Terminal.prototype.appendRows_ = function(count) {
  var sp = this.scrollPort_;
  var previousLength = this.scrollbackRows_.length;
  var anchor = previousLength ? this.scrollbackRows_[previousLength - 1] : null;
  var wasReadingBack = !!(sp && !sp.isScrolledEnd);

  _moshroomBaseAppendRows.call(this, count);

  // This runs once per output LINE, so it gets out of the way first: a trim is the only thing that can
  // leave the scrollback SHORTER than it was (rows are otherwise only pushed onto it), and the search
  // for the surviving row only happens on that.
  if (this.scrollbackRows_.length >= previousLength || !wasReadingBack || !anchor || !sp || !sp.scroller_) {
    return;
  }
  var dropped = (previousLength - 1) - this.scrollbackRows_.indexOf(anchor);
  var ch = sp.characterSize.height;
  var y = sp.scroller_._y;
  if (dropped > 0 && ch > 0 && typeof y === 'number' && y > 0) {
    sp.scroller_.scrollTo(0, Math.max(y - dropped * ch, 0), false, true);
  }
};

// The other half of the same story: hterm re-arms its "follow the output" scroll from two places, a
// row shifting off the screen (already gated on being at the end) and the TRIM above (not gated at
// all). Gate both, so the trim compensation is not immediately undone by a scroll to the bottom.
var _moshroomBaseScheduleScrollDown = hterm.Terminal.prototype.scheduleScrollDown_;
hterm.Terminal.prototype.scheduleScrollDown_ = function() {
  if (this.scrollPort_ && !this.scrollPort_.isScrolledEnd) {
    return;
  }
  _moshroomBaseScheduleScrollDown.call(this);
};

// ---- Sub-row (pixel-smooth) scrolling --------------------------------------------------------
// hterm redrew only when the TOP ROW INDEX changed and never applied the remainder, so a finger
// moving continuously dragged the text in whole-row steps (~18pt at the default font): the one
// thing that most gave away "this is not a native terminal". The remainder is now a compositor
// transform on the row container (plus the cursor overlay, which must move with it), with one extra
// row rendered so the bottom of the viewport is never a gap. Rows are still only re-rendered once
// per row crossed, so the cost of this is one transform per frame.
var _moshroomLastTopRow = -1;
var _moshroomLastBottomRow = -1;

// The live scroll position in pixels. The module-private copy hterm keeps (`Ee`) is unreachable from
// here, but the scroller object holds the same value, and it is the more current of the two: a
// hterm-initiated scroll sets it immediately, while hterm's copy only catches up once the native
// round trip reports back.
function _moshroomScrollTop(sp) {
  var scroller = sp.scroller_;
  var y = scroller ? scroller._y : 0;
  if (typeof y !== 'number') {
    return 0;
  }
  // Clamped to the content's TRUE extent at both ends, which is what keeps the rows welded to the
  // viewport:
  //
  // - Past the end, hterm's own scroll-to-end target overshoots by the bottom margin (getScrollMax_
  //   adds margins the content height already carries) and a scroll view accepts a programmatic
  //   offset beyond its limit, so the SAME live end rendered two different ways: flush when output
  //   had scrolled there, top row sliced off when scrollEnd had.
  // - Before the start, a rubber-band overscroll reports a NEGATIVE offset, and hterm answered it by
  //   translating the rows DOWN, which opened a gap at the top of the terminal filled with nothing
  //   but the page background. In a shell that is invisible (same colour); in any full-screen program
  //   that paints its own canvas it is a fat dark band appearing under the finger on every over-drag,
  //   which is the "black strip when scrolling up" this clamp removes. Measured on Catalyst with a
  //   phase-tagged (trackpad-style) scroll against a blue canvas: 96pt of theme background before,
  //   none after. The scroll view no longer bounces either (see WKWebView.swift), so this is the
  //   second of two locks on the same door.
  var max = (scroller._contentHeight || 0) - (scroller._viewHeight || 0);
  if (y > max) {
    y = max;
  }
  return y > 0 ? y : 0;
}

// hterm ROUNDED the offset to the nearest row, which is only right when the viewport is always
// parked on a row boundary. With a sub-row shift the top row is the one the offset is INSIDE.
hterm.ScrollPort.prototype.getTopRowIndex = function() {
  var ch = this.characterSize.height;
  var y = _moshroomScrollTop(this);
  if (!(ch > 0) || y <= 0) {
    return 0;
  }
  return Math.floor(y / ch);
};

function _moshroomApplySubRowOffset(sp) {
  if (!sp.rowNodes_) {
    return;
  }
  var ch = sp.characterSize.height;
  var y = _moshroomScrollTop(sp);              // never negative, never past the end
  var shift = ch > 0 ? y - Math.floor(y / ch) * ch : 0;   // the remainder inside the top row
  var css = shift ? 'translate3d(0, ' + (-shift) + 'px, 0)' : '';
  if (sp.rowNodes_.style.transform !== css) {
    sp.rowNodes_.style.transform = css;
  }
  var overlay = sp.rowProvider_ ? sp.rowProvider_.cursorOverlayNode_ : null;
  if (overlay && overlay.style.transform !== css) {
    overlay.style.transform = css;
  }
}

// One row more than fits: with a sub-row shift the last row is partly above the fold, and the strip
// left over by a viewport that is not a whole number of rows tall would otherwise be blank.
hterm.ScrollPort.prototype.drawVisibleRows_ = function(topRowIndex, bottomRowIndex) {
  var total = this.rowProvider_.getRowCount();
  var count = Math.min(this.visibleRowCount + 1, total);
  var rows = [];
  for (var i = 0; i < count; i++) {
    var node = this.fetchRowNode_(topRowIndex + i);
    if (node) {
      rows.push(node);
    }
  }
  this.renderRef.setRows(rows);
};

// Replaces hterm's version wholesale: the redraw decision has to use the same quantisation as
// getTopRowIndex above (hterm's used its own rounding, so a floor-based top row could change with no
// redraw scheduled and the transform would render the wrong row at the wrong offset), and the
// no-redraw case still has to move the pixels.
hterm.ScrollPort.prototype.onScroll_ = function(e) {
  var size = this.getScreenSize();
  if (size.width !== this.lastScreenWidth_ || size.height !== this.lastScreenHeight_) {
    this.resize();
    return;
  }
  var top = this.getTopRowIndex();
  var bottom = this.getBottomRowIndex(top);
  if (top !== _moshroomLastTopRow || bottom !== _moshroomLastBottomRow) {
    _moshroomLastTopRow = top;
    _moshroomLastBottomRow = bottom;
    this.redraw_();                            // ends in syncRowNodesDimensions_, see below
    this.publish('scroll', {scrollPort: this});
  } else {
    _moshroomApplySubRowOffset(this);
  }
  // Our scroll produces no DOM scroll event: the selection highlight follows the rows from here.
  if (_mshSel) {
    _mshPaint();
  }
};

// Every redraw ends here, and the base version resets the transform (it only knows the bounce
// case), so this is where the shift has to be re-asserted: output arriving mid-scroll redraws.
var _moshroomBaseSyncRowNodesDimensions = hterm.ScrollPort.prototype.syncRowNodesDimensions_;
hterm.ScrollPort.prototype.syncRowNodesDimensions_ = function() {
  _moshroomBaseSyncRowNodesDimensions.call(this);
  _moshroomApplySubRowOffset(this);
  // Same frame as the shift, so the highlight never trails the text it covers.
  if (_mshSel) {
    _mshPaint();
  }
};

// The native side quantises the finger into whole rows and passes the COUNT, because hterm's VT
// encodes exactly ONE wheel report per event: a single report for a 3-row flick made every TUI
// scroll a third of the way the finger went, which is what read as sluggish and imprecise.
function term_reportWheelEvent(name, x, y, deltaX, deltaY, rows) {
  if (!t || !t.prompt || !t.scrollPort_ || !t.vt) {
    return;
  }
  var count = parseInt(rows, 10);
  count = Math.max(1, Math.min(count > 0 ? count : 1, 12));

  if (_moshroomMouseReportOn()) {
    var step = deltaY / count;
    for (var i = 0; i < count; i++) {
      var event = new WheelEvent(name, {clientX: x, clientY: y, deltaX: 0, deltaY: step});
      // Stamp the terminal row/column on the wheel event, exactly like the mouse path does, so
      // the SGR wheel report lands on the cell under the finger instead of a default position.
      // Without this a swipe scrolls whatever panel sits at the origin (often a TUI's input box)
      // rather than the content the user is actually dragging over.
      _setTermCoordinates(event, x, y);
      t.onMouse_Moshroom(event);
    }
    return;
  }

  // Rungs 2 and 3 apply on EITHER screen. The native side sends the gesture here whenever the local
  // scrollback cannot serve it, which includes a full-screen program rendering inline on the normal
  // screen: rung 2's own guards find nothing above such a screen and rung 3 pages it.
  var up = deltaY < 0;
  if (_moshroomScrollAltLocally(up, count)) {
    return;
  }
  _moshroomSendAltScrollKeys(up, count);
}

// Rung 2: the alternate screen's own scrollback. Up is offered while there is text within reach
// above the viewport; down only while parked above the live end, so the live end always hands the
// gesture on and a pager stays pageable.
function _moshroomScrollAltLocally(up, count) {
  var sp = t.scrollPort_;
  var top = sp.getTopRowIndex();
  if (up) {
    if (top <= 0) {
      return false;
    }
    var from = Math.max(0, top - _moshroomHistoryScanRows);
    if (!/\S/.test(t.getRowsText(from, top))) {
      return false;    // only the blank run above a freshly entered full-screen program
    }
    sp.scrollRowToTop(Math.max(0, top - count));
    return true;
  }
  var liveTop = Math.max(0, t.getRowCount() - sp.visibleRowCount);
  if (top >= liveTop) {
    return false;
  }
  sp.scrollRowToTop(Math.min(liveTop, top + count));
  return true;
}

// Rung 3: one Down per row, and never an Up (see the ladder's note). The whole gesture goes out as
// ONE write, which is what keeps tmux's escape-time from splitting the sequence and leaking a
// literal "[B" onto the command line, and the burst is capped so a flick cannot run away. SS3 vs CSI
// is not cosmetic: with DECCKM set (every pager and full-screen app sets it) `less` answers to
// \x1bOB and ignores \x1b[B.
function _moshroomSendAltScrollKeys(up, count) {
  if (up) {
    return;
  }
  var prefix = (t.keyboard && t.keyboard.applicationCursor) ? '\x1bO' : '\x1b[';
  var out = '';
  for (var i = 0; i < Math.min(count, 3); i++) {
    out += prefix + 'B';
  }
  t.io.sendString(out);
}

// ---- Universal tap interactivity ------------------------------------------------------------
// A tap on the terminal is dispatched through GENERIC terminal mechanisms only — nothing is
// specific to any one TUI: OSC 8 hyperlinks, URLs in the rendered text (hterm's own expansion),
// standard mouse reporting (DECSET 1000/1002/1006 — any program that asked for mouse events gets
// a real click report), and the cursor position (the one universal marker of "the program reads
// input HERE" — every REPL and TUI parks its cursor in the focused text field).
//
// Returns {action, input} to the native tap recognizer:
//   action 'url'   — a link was under the tap; it was already routed to hterm.openUrl
//          'click' — mouse reporting is on; a left press+release was reported at the cell
//          'none'  — nothing consumed the tap
//   input  true    — the tap landed on the cursor row (the program's input line): typing intent,
//                    native opens the composer. Suppresses the plain-text URL check (a URL the
//                    user typed into their own input line must not hijack the tap), but not
//                    OSC 8 (a real anchor is a link wherever it sits).
function term_tapAt(x, y) {
  var none = {action: 'none', input: false};
  if (!t || !t.scrollPort_) {
    return none;
  }
  // An existing selection owns the gesture (native turns the tap into "dismiss" or "show the
  // copy pill" before it gets here); never probe or clobber it.
  if (_mshSel) {
    return none;
  }

  // 1) OSC 8 hyperlink: hterm renders them as .uri-node spans (title = the target).
  var el = document.elementFromPoint(x, y);
  while (el && el.nodeType === 1 && el.tagName !== 'X-SCREEN') {
    if (el.classList && el.classList.contains('uri-node') && el.title) {
      hterm.openUrl(el.title);
      return {action: 'url', input: false};
    }
    el = el.parentElement;
  }

  var input = _moshroomTapOnCursorRow(y);

  // 2) A plain URL in the rendered text — works for any program that ever printed one.
  if (!input) {
    var url = _moshroomUrlAtPoint(x, y);
    if (url) {
      hterm.openUrl(url);
      return {action: 'url', input: false};
    }
  }

  // 3) The program asked for mouse events: report a real left click at the cell, through the
  //    exact pipeline the wheel path already uses (hterm's VT encodes SGR/X10 and sends it).
  if (t.vt && t.vt.mouseReport !== t.vt.MOUSE_REPORT_DISABLED && !t.defeatMouseReports_) {
    _moshroomReportClick(x, y);
    return {action: 'click', input: input};
  }

  return {action: 'none', input: input};
}

// The tap row vs the cursor row, decided by ON-SCREEN GEOMETRY: the cursor node is positioned
// by the same rendering pipeline as the text, so its client rect is the one truth that cannot
// drift from what the user sees (a tap on scrolled-away history still never matches: the node
// is parked off-viewport then). The previous row arithmetic (scrollback length + cursor row -
// top row index) went stale the moment the alternate screen accumulated scrollback of its own:
// the strict row equality failed and a tap on a mosh/tmux input line stopped opening the
// composer, falling through to selection instead.
function _moshroomTapOnCursorRow(y) {
  if (!t.options_.cursorVisible || !t.cursorNode_ || !t.cursorNode_.getBoundingClientRect) {
    return false;
  }
  var r = t.cursorNode_.getBoundingClientRect();
  if (!r || r.height <= 0) {
    return false;
  }
  return y >= r.top && y < r.bottom;
}

// Find a URL in the rendered text under (x, y), read from the row model: the logical line through
// the tapped row (rows hterm wrapped into one, joined through their overflow flag), so a URL wrapped
// across rows opens WHOLE. No selection is created. Only an EXPLICIT link counts: a scheme
// (https://, mailto:) or a www. host, so a tap never invents links out of random words.
function _moshroomUrlAtPoint(x, y) {
  if (!_mshReady()) {
    return null;
  }
  var g = _mshGeom();
  if (y < g.view.top || y >= g.view.bottom) {
    return null;
  }
  var R = _mshRowAtY(y, g);
  var line = _mshLogicalLine(R);
  var hit = _mshUrlInLine(line, _mshLineCellIndex(line, R, _mshCellAt(x, R, g)));
  if (!hit) {
    return null;
  }
  var url = hit.url;
  if (/^www\./i.test(url)) {
    url = 'https://' + url;
  }
  return url.length > 2048 ? null : url;
}

// Synthetic left press+release with the terminal cell stamped on, exactly like the wheel path —
// t.onMouse is hterm.VT's onTerminalMouse_, which encodes and io.sendString()s the report. This
// bypasses onMouse_Moshroom's DOM-selection housekeeping (built for real browser events).
function _moshroomReportClick(x, y) {
  // Same row math as hterm's own event stamping (clientY minus the scrollport's top margin).
  var my = y - t.scrollPort_.visibleRowTopMargin;
  var down = new MouseEvent('mousedown', {clientX: x, clientY: y, button: 0, buttons: 1});
  _setTermCoordinates(down, x, my);
  t.onMouse(down);
  var up = new MouseEvent('mouseup', {clientX: x, clientY: y, button: 0, buttons: 0});
  _setTermCoordinates(up, x, my);
  t.onMouse(up);
}

function term_setWidth(cols) {
  t.setWidth(cols);
}

function term_increaseFontSize() {
  var size = t.getFontSize();
  term_setFontSize(size + 1 + 'px');
}

function term_decreaseFontSize() {
  var size = t.getFontSize();
  term_setFontSize(size - 1 + 'px');
}

function term_setFontSize(size) {
  term_set('font-size', size);
  _postMessage('fontSizeChanged', {size: parseInt(size)});
}

function term_setFontFamily(name, fontSizeDetectionMethod) {
  window.fontSizeDetectionMethod = fontSizeDetectionMethod;
  term_set('font-family', name + ', "DejaVu Sans Mono"');
}

function term_setClipboardWrite(state) {
  if (state === false) {
    t.vt.enableClipboardWrite = false;
  } else {
    t.vt.enableClipboardWrite = true;
  }
}

function term_appendUserCss(css) {
  var style = document.createElement('style');

  style.type = 'text/css';
  style.appendChild(document.createTextNode(css));

  document.head.appendChild(style);
}

function waitForFontFamily(callback) {
  const fontFamily = term_get('font-family');
  if (!fontFamily) {
    return callback();
  }

  const families = fontFamily.split(/\s*,\s*/);

  WebFont.load({
    custom: {families},
    active: callback,
    inactive: callback,
  });
}

function term_applySexyTheme(theme) {
  term_set('color-palette-overrides', theme.color);
  term_set('foreground-color', theme.foreground);
  term_set('background-color', theme.background);
}

// Palette BLACK is the terminal's background, not #000. A full-screen program that fills a row with
// an explicit black background is assuming the terminal's own background is black as well, which is
// the near-universal assumption for a dark TUI: on a black terminal it blends invisibly. Moshroom's
// background is the house near-black, so the same row arrives as a hard black BAND across the
// terminal, and that is exactly the "black strip" Álvaro kept seeing (measured in a live mosh + tmux
// + agent session: one full-width row, bci 0 and fci 0, pure #000 against our rgb(16,16,16)).
// Making the two agree costs nothing that was legible before: black-on-the-default-background was
// already invisible, black on a coloured background stays perfectly readable a shade lighter, and
// every black area a program paints now lands ON our background instead of cutting a hole in it.
// Reads the PREF rather than the terminal, so it also works while running inside applyUserSettings(),
// before hterm is decorated. Idempotent.
function _moshroomBlendPaletteBlack() {
  var bg = term_get('background-color');
  if (!bg) {
    return;
  }
  var palette = term_get('color-palette-overrides');
  var next;
  if (Array.isArray(palette)) {
    if (palette[0] === bg) {
      return;
    }
    next = palette.slice();
  } else if (palette && typeof palette === 'object') {
    if (palette[0] === bg) {
      return;
    }
    next = {};
    for (var key in palette) {
      if (Object.prototype.hasOwnProperty.call(palette, key)) {
        next[key] = palette[key];
      }
    }
  } else {
    next = {};
  }
  next[0] = bg;
  term_set('color-palette-overrides', next);
}

function term_setAutoCarriageReturn(state) {
  t.setAutoCarriageReturn(state);
}

// ---- Moshroom tmux: scrollback tail (owned by the tmux child session, Moshroom/Commands/tmux) ----
// The last `n` lines the primary screen has scrolled off into its scrollback, oldest first, trailing
// blanks trimmed, wrapped rows joined back into their line. A tmux tab that re-attaches matches these
// against tmux's own history to append only what this terminal has not seen. Answers JSON:
// {primary: Bool, lines: [String]}; primary is false while the alternate screen is showing (it banks no
// history of the session's shell).
function term_moshroomScrollbackTail(n) {
  try {
    if (!t || !t.isPrimaryScreen()) {
      return JSON.stringify({primary: false, lines: []});
    }
    var rows = t.scrollbackRows_ ? t.scrollbackRows_.length : 0;
    if (rows === 0) {
      return JSON.stringify({primary: true, lines: []});
    }
    // A line may span several rows: read enough of them, then drop a first line that may have started
    // before the window.
    var from = Math.max(0, rows - n * 8);
    var lines = t.getRowsText(from, rows).split('\n');
    if (from > 0) {
      lines.shift();
    }
    lines = lines.slice(-n).map(function(line) { return line.replace(/\s+$/, ''); });
    return JSON.stringify({primary: true, lines: lines});
  } catch (e) {
    return JSON.stringify({primary: false, lines: []});
  }
}
// ---- end Moshroom tmux ----
