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

  document.getSelection().removeAllRanges();
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

// ---- Selection painter (both platforms) ------------------------------------------------------
// The selection highlight is OURS: translucent red rects derived from the live Range's client
// geometry, in a fixed, non-interactive overlay. On the Mac it is the ONLY red (WebKit's own
// selection painting is unreliable there — its activity-state latches — so ::selection is
// transparent and this painter is the single source of truth). On iOS it rides ON TOP of the
// native selection (which stays: the grab handles and their red tint are UIKit chrome above the
// page), giving both platforms the same strong red. Repainted on every selectionchange (fires
// per step of a live drag / handle drag) and on scroll/resize.
var _moshroomSelOverlay = null;

// A Range over terminal rows reports OVERLAPPING client rects: for each selected row there is the
// full row box AND the narrower box around the glyphs inside it. Painting every rect composited the
// translucent red twice wherever they overlapped, so the highlight came out in two shades — darker
// over the text, lighter over the empty tail of the line. Keep only the rects that no other rect
// already covers (equal duplicates keep the first), so every pixel of a selection gets exactly one
// coat and the red is uniform.
function _moshroomDedupeRects(rects) {
  var out = [];
  for (var i = 0; i < rects.length; i++) {
    var r = rects[i];
    if (r.width <= 0 || r.height <= 0) {
      continue;
    }
    var covered = false;
    for (var j = 0; j < rects.length && !covered; j++) {
      if (j === i) {
        continue;
      }
      var o = rects[j];
      if (o.width <= 0 || o.height <= 0) {
        continue;
      }
      var contains = o.left <= r.left + 1 && o.top <= r.top + 1 &&
                     o.right >= r.right - 1 && o.bottom >= r.bottom - 1;
      if (!contains) {
        continue;
      }
      var areaO = o.width * o.height;
      var areaR = r.width * r.height;
      // Strictly bigger wins; between identical rects the earlier index survives.
      covered = areaO > areaR || (areaO === areaR && j < i);
    }
    if (!covered) {
      out.push(r);
    }
  }
  return out;
}

// A selection that spans more than one row highlights every row but the last one all the way to the
// END OF THE LINE — the convention in every browser and terminal, and also exactly what the platform's
// own selection layer underneath paints (that layer follows the web view's red tintColor and shows
// through at a low alpha). The Range's rect for the FIRST row stops where that row's text stops, so
// without this the tail of the first row was left with only the faint platform tint: the same
// selection appeared in two different shades. Widen every row except the bottom-most to the row width.
function _moshroomFillToLineEnd(rects) {
  if (rects.length < 2) {
    return rects;
  }
  var rowWidth = 0;
  var bottomTop = -Infinity;
  for (var i = 0; i < rects.length; i++) {
    rowWidth = Math.max(rowWidth, rects[i].right);
    bottomTop = Math.max(bottomTop, rects[i].top);
  }
  var screen = t && t.scrollPort_ ? t.scrollPort_.screen_ : null;
  if (screen && screen.clientWidth > rowWidth) {
    rowWidth = screen.clientWidth;
  }
  var out = [];
  for (var j = 0; j < rects.length; j++) {
    var r = rects[j];
    if (r.top >= bottomTop - 1 || r.right >= rowWidth - 1) {
      out.push(r);
      continue;
    }
    out.push({left: r.left, top: r.top, width: rowWidth - r.left, height: r.height});
  }
  return out;
}

function _moshroomPaintSelection() {
  if (!_moshroomSelOverlay) {
    _moshroomSelOverlay = document.createElement('div');
    _moshroomSelOverlay.style.cssText =
      'position:fixed;inset:0;pointer-events:none;z-index:2147483646;';
    (document.body || document.documentElement).appendChild(_moshroomSelOverlay);
  }
  _moshroomSelOverlay.textContent = '';
  var sel = document.getSelection();
  if (!sel || sel.rangeCount === 0 || sel.isCollapsed) {
    return;
  }
  var rects = _moshroomFillToLineEnd(_moshroomDedupeRects(sel.getRangeAt(0).getClientRects()));
  for (var i = 0; i < rects.length; i++) {
    var r = rects[i];
    if (r.width <= 0 || r.height <= 0) {
      continue;
    }
    var d = document.createElement('div');
    d.style.cssText = 'position:fixed;background:rgba(255,82,90,0.45);' +
      'left:' + r.left + 'px;top:' + r.top + 'px;width:' + r.width + 'px;height:' + r.height + 'px;';
    _moshroomSelOverlay.appendChild(d);
  }
}

document.addEventListener('scroll', _moshroomPaintSelection, true);
window.addEventListener('resize', _moshroomPaintSelection);

document.addEventListener('selectionchange', function() {
  var current = term_getCurrentSelection();
  // Selection gone (copied, cleaned, or the TUI redrew the rows under it) — drop the
  // selectability override so the terminal is back to its scroll-not-select default.
  if (!current.text) {
    _moshroomSetSelecting(false);
  }
  _moshroomPaintSelection();
  _postMessage('selectionchange', current);
});

// A double/triple-click on a BLANK region makes WebCore select the whole whitespace run — a huge
// ghost rectangle over empty rows. Kill exactly that after the click settles (a drag's mouseup
// arrives with detail 1 and single clicks carry no selection, so neither is touched).
document.addEventListener('mouseup', function(e) {
  if (e.detail >= 2) {
    var sel = document.getSelection();
    if (sel && sel.toString() && !sel.toString().trim()) {
      sel.removeAllRanges();
    }
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
  // Never translate wheel/swipe into arrow keys on the alternate screen. At a shell prompt
  // inside tmux/mosh (alt screen, no mouse reporting) every wheel tick became \x1bOA/\x1bOB:
  // it cycled the shell history under the user's finger and, split at tmux's escape-time,
  // leaked literal "[A"/"[B" onto the command line. TUIs that want scroll ask for mouse
  // reporting and get real wheel reports; that path does not depend on this preference.
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
    term_setClipboardWrite(true);   // let apps/agents copy to the iOS clipboard via OSC 52

    t.setCursorVisible(true);
    // No terminal cursor block at the prompt — you type in Moshkitor, not here. Make hterm's
    // cursor transparent so the stray blue rectangle is gone. (The contentEditable insertion caret
    // is killed at the root by -webkit-user-modify:read-only below — the terminal is display-only.)
    t.setCursorColor('rgba(0, 0, 0, 0)');

    // Moshroom: on touch devices the terminal is a scroll + keys surface, not a document —
    // native text selection hijacks the pan gesture (a swipe selects instead of scrolling, and
    // the selection cancels the scroll), so user-select is OFF there; the long-press word-select
    // (term_selectWordAt) briefly re-enables it via .moshroom-selecting so the red ::selection
    // styling applies (WebKit refuses ::selection on user-select:none content and paints the
    // platform theme colour instead). On the Mac (Catalyst) it's the opposite: scrolling comes
    // from the wheel/trackpad (DOM wheel events hterm handles itself), and a mouse drag or
    // double-click is EXPECTED to select — so text stays selectable there all the time.
    var _moshroomIsMac = /Mac/.test(navigator.platform);
    // The terminal is a READ-ONLY display: you never type into it (special keys go straight through
    // TermDevice; any text is composed in Moshkitor). hterm marks its <x-screen> contentEditable, so
    // iOS WebKit focuses it on tap and paints an insertion caret there (and caret-color:transparent is
    // NOT honored for that tap-positioned caret on iOS). Force -webkit-user-modify:read-only so the
    // element is not an editing host at all — no caret ever, on any platform — while -webkit-user-select
    // still allows selecting text (long-press on iOS, drag on the Mac) for Copy.
    var _moshroomSelectRules = _moshroomIsMac
      ? '*{-webkit-user-select:text!important;-webkit-user-modify:read-only!important;-webkit-touch-callout:none!important;caret-color:transparent!important;}'
      : '*{-webkit-user-select:none!important;-webkit-user-modify:read-only!important;-webkit-touch-callout:none!important;caret-color:transparent!important;}.moshroom-selecting *{-webkit-user-select:text!important;}';
    // …plus the Moshroom-red selection highlight. On iOS that's real ::selection CSS (and the
    // grab handles follow the web view's tintColor, also Moshroom red). On the Mac, ::selection
    // is made TRANSPARENT instead: WebKit's own selection painting there depends on a volatile
    // window/responder activity state with at least three observed latch modes (page-red /
    // UIKit-overlay / dead near-black box — the last one born whenever a selection is created
    // while the window is still becoming key, and persisting after), so the red is painted by
    // OUR overlay (see _moshroomPaintSelection), which only depends on the live Range geometry
    // and never on WebKit's mood.
    var _moshroomSelectionCss = _moshroomIsMac
      ? '::selection{background-color:transparent!important;color:inherit!important;}::selection:window-inactive{background-color:transparent!important;color:inherit!important;}'
      : '::selection{background-color:rgba(255,82,90,1)!important;color:inherit!important;}::selection:window-inactive{background-color:rgba(255,82,90,1)!important;color:inherit!important;}';
    var _moshroomScreen = t.scrollPort_.screen_;
    if (_moshroomScreen) {
      var _moshroomDoc = _moshroomScreen.ownerDocument;
      var _moshroomStyle = _moshroomDoc.createElement('style');
      _moshroomStyle.textContent = _moshroomSelectRules + _moshroomSelectionCss;
      (_moshroomDoc.head || _moshroomDoc.documentElement).appendChild(_moshroomStyle);
    }

    // No text caret anywhere in the terminal — input happens in Moshkitor, so the blinking
    // insertion bar at the top-left is just a stray vestige. Hide it on the main document too.
    var _moshroomCaretStyle = document.createElement('style');
    _moshroomCaretStyle.textContent = '*{caret-color:transparent!important;-webkit-user-modify:read-only!important;}' + (_moshroomIsMac ? '' : '.moshroom-selecting *{-webkit-user-select:text!important;}') + _moshroomSelectionCss;
    (document.head || document.documentElement).appendChild(_moshroomCaretStyle);
    document.body.style.caretColor = 'transparent';

    t.io.onTerminalResize = function(cols, rows) {
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
    
    t.keyboard.characterEncoding = 'raw'; // we are UTF8. Fix for #507
    t.uninstallKeyboard();
    
    _postMessage('terminalReady', {size, bgColor});

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
  t.interpret(data);
}

function term_paste(str) {
  t.onPaste_({text: str || ''});
}

var _utf8TextDecoder = new TextDecoder('utf8');
function term_write_b64(b64str) {
  var bytes = base64js.toByteArray(b64str);
  var data = _utf8TextDecoder.decode(bytes);
  t.interpret(data);
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

function term_reportWheelEvent(name, x, y, deltaX, deltaY) {
  if (!t.prompt) {
    return;
  }

  var event = new WheelEvent(name, {clientX: x, clientY: y, deltaX, deltaY});
  // Stamp the terminal row/column on the wheel event, exactly like the mouse path does, so
  // the SGR wheel report lands on the cell under the finger instead of a default position.
  // Without this a swipe scrolls whatever panel sits at the origin (often a TUI's input box)
  // rather than the content the user is actually dragging over.
  _setTermCoordinates(event, x, y);
  t.onMouse_Moshroom(event);
}

// While a selection is alive, the selected text must be *selectable* in CSS terms: WebKit skips
// `::selection` styling for `user-select: none` content and falls back to the platform theme
// colour — on Mac Catalyst that's the system accent (blue), on an unfocused page a dull gray.
// The blanket user-select:none (a swipe must scroll, never select) stays; this class scopes
// text-selectability to exactly the lifetime of a Moshroom-made selection so the highlight is
// always the Moshroom red.
function _moshroomSetSelecting(on) {
  document.documentElement.classList.toggle('moshroom-selecting', !!on);
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
  // An existing selection owns the gesture (a tap dismisses it; a Mac dblclick just made one) —
  // never probe or clobber it.
  var sel = document.getSelection();
  if (sel && sel.toString()) {
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

// Find a URL in the rendered text under (x, y). Pure DOM read — no selection is created, no
// hterm internals touched (this hterm build models screen rows as records, so its own
// expandSelectionForUrl machinery cannot run against a DOM caret). The tapped x-row's text is
// assembled (joined with its wrapped continuation rows via the line-overflow attribute), the
// tap's character offset located, and a URL match containing that offset wins. Only an EXPLICIT
// link counts: a scheme (https://, mailto:) or a www. host — a tap must never invent links out
// of random words.
var _moshroomUrlRegex = /(?:[a-z][a-z0-9+.-]*:\/\/|www\.|mailto:)[^\s\[\](){}<>"'`]+/gi;

function _moshroomUrlAtPoint(x, y) {
  var range = document.caretRangeFromPoint(x, y);
  if (!range || range.startContainer.nodeType !== Node.TEXT_NODE) {
    return null;
  }
  var node = range.startContainer;
  var row = node.parentElement;
  while (row && row.nodeName !== 'X-ROW') {
    row = row.parentElement;
  }
  if (!row) {
    return null;
  }

  // The logical line: walk back while the PREVIOUS row overflows into ours, then forward while
  // the current row overflows into the next — so a URL wrapped across rows is seen whole.
  var overflows = function(r) { return r && r.hasAttribute && r.hasAttribute('line-overflow'); };
  var first = row;
  while (first.previousSibling && overflows(first.previousSibling)) {
    first = first.previousSibling;
  }
  var rows = [first];
  var last = first;
  while (overflows(last) && last.nextSibling && last.nextSibling.nodeName === 'X-ROW') {
    last = last.nextSibling;
    rows.push(last);
  }

  // Assemble the line text and locate the tapped character's offset within it.
  var text = '';
  var offset = -1;
  for (var i = 0; i < rows.length; i++) {
    var walker = document.createTreeWalker(rows[i], NodeFilter.SHOW_TEXT);
    var n;
    while ((n = walker.nextNode())) {
      if (n === node) {
        offset = text.length + range.startOffset;
      }
      text += n.textContent;
    }
  }
  if (offset < 0) {
    return null;
  }

  _moshroomUrlRegex.lastIndex = 0;
  var m;
  while ((m = _moshroomUrlRegex.exec(text))) {
    if (offset >= m.index && offset < m.index + m[0].length) {
      // Trailing punctuation belongs to the prose, not the link.
      var url = m[0].replace(/[.,;:!?'")\]}>]+$/, '');
      if (/^www\./i.test(url)) {
        url = 'https://' + url;
      }
      if (url.length > 2048) {
        return null;
      }
      return url;
    }
  }
  return null;
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

// Select the whole terminal word under (x, y) — used by the native long-press to offer Copy.
// Works for any TUI because it just selects the rendered on-screen text. A `selectionchange`
// then fires and the native side shows a single Copy item.
function term_selectWordAt(x, y) {
  var sel = document.getSelection();
  if (!sel) {
    return;
  }
  var range = document.caretRangeFromPoint(x, y);
  if (!range) {
    return;
  }
  _moshroomSetSelecting(true);
  sel.removeAllRanges();
  sel.addRange(range);
  if (sel.modify) {
    sel.modify('move', 'backward', 'word');
    sel.modify('extend', 'forward', 'word');
  }
  // A long-press on an empty cell must select NOTHING: extending a caret in blank rows grabs a
  // ghost whitespace selection spanning the whole screen (painted as a full-viewport highlight).
  if (!sel.toString().trim()) {
    sel.removeAllRanges();
    _moshroomSetSelecting(false);
  }
}

// Live mouse drag-selection (Mac Catalyst): WebKit there never turns a click-drag into a WebCore
// drag selection on its own, so the native side drives one — anchor at mouse-down, extend on
// every drag step, and settle on mouse-up (a drag that grabbed nothing but whitespace clears,
// same rule as term_selectWordAt).
function term_startSelectionAt(x, y) {
  var sel = document.getSelection();
  if (!sel) {
    return;
  }
  var range = document.caretRangeFromPoint(x, y);
  if (!range) {
    return;
  }
  _moshroomSetSelecting(true);
  sel.removeAllRanges();
  sel.addRange(range);
}

function term_extendSelectionTo(x, y) {
  var sel = document.getSelection();
  if (!sel || sel.rangeCount === 0) {
    return;
  }
  var range = document.caretRangeFromPoint(x, y);
  if (!range) {
    return;
  }
  sel.extend(range.startContainer, range.startOffset);
}

function term_endSelection() {
  var sel = document.getSelection();
  if (sel && !sel.toString().trim()) {
    sel.removeAllRanges();
    _moshroomSetSelecting(false);
  }
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

function term_getCurrentSelection() {
  const selection = document.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.type === 'Caret') {
    return {base: '', offset: 0, text: ''};
  }

  const r = selection.getRangeAt(0).getBoundingClientRect();

  const rect = `{{${r.x}, ${r.y}},{${r.width},${r.height}}}`;

  return {
    base: selection.baseNode.textContent,
    offset: selection.baseOffset,
    text: selection.toString() || "",
    rect,
  };
}

function _modifySelectionByLine(direction) {
  var selection = document.getSelection();
  var fNode = selection.focusNode;
  var fOffset = selection.focusOffset;
  var aNode = selection.anchorNode;
  var aOffset = selection.anchorOffset;

  var dy =
    direction === 'left'
      ? -t.scrollPort_.characterSize.height
      : t.scrollPort_.characterSize.height;
  var dx = t.scrollPort_.characterSize.width;
  var range = selection.getRangeAt(0);

  var topLeft = true;
  if (fNode === aNode) {
    topLeft = fOffset < aOffset;
  } else {
    topLeft = range.compareNode(selection.focusNode) !== Range.NODE_AFTER;
  }

  if (topLeft) {
    // top left
    var rect = _filteredRects(range)[0];
    var point = {x: rect.left, y: rect.top + Math.abs(dy) * 0.5};
    var newRange = document.caretRangeFromPoint(point.x, point.y + dy);
    if (!newRange) {
      selection.modify('extend', direction, 'line');
    } else {
      if (newRange.startContainer.textContent.length <= newRange.startOffset) {
        if (
          newRange.startContainer.nodeName === 'X-ROW' &&
          newRange.startOffset === 0
        ) {
          selection.setBaseAndExtent(
            aNode,
            aOffset,
            newRange.startContainer,
            newRange.startOffset,
          );
          selection.modify('extend', 'left', 'character');
        } else {
          selection.setBaseAndExtent(
            aNode,
            aOffset,
            newRange.startContainer,
            Math.max(newRange.startOffset - 1, 0),
          );
        }
      } else {
        selection.setBaseAndExtent(
          aNode,
          aOffset,
          newRange.startContainer,
          newRange.startOffset,
        );
      }
    }
  } else {
    // bottom right
    var rects = _filteredRects(range);
    var rect = rects[rects.length - 1];
    var point = {x: rect.right, y: rect.bottom - Math.abs(dy) * 0.5};
    var newRange = document.caretRangeFromPoint(point.x, point.y + dy);
    if (newRange == null) {
      point.x -= dx * 0.5;
    }
    newRange = document.caretRangeFromPoint(point.x, point.y + dy);
    selection.setBaseAndExtent(
      aNode,
      aOffset,
      newRange.startContainer,
      newRange.startOffset,
    );
  }
}

function _filteredRects(range) {
  var res = [];
  var rects = range.getClientRects();
  for (var i = 0; i < rects.length; i++) {
    var r = rects[i];
    if (r.width > 0) {
      res.push(r);
    }
  }
  return res;
}

function term_modifySelection(direction, granularity) {
  var selection = document.getSelection();
  if (!selection || selection.rangeCount === 0) {
    return;
  }

  var fNode = selection.focusNode;
  var fOffset = selection.focusOffset;
  var aNode = selection.anchorNode;
  var aOffset = selection.anchorOffset;

  if (granularity === 'line') {
    _modifySelectionByLine(direction);
    if (selection.isCollapsed) {
      selection.setBaseAndExtent(fNode, fOffset, aNode, aOffset);
      _modifySelectionByLine(direction);
    }

    return;
  }

  selection.modify('extend', direction, granularity);

  // we collapse selection, so swap direction and rerun modification again
  if (selection.isCollapsed) {
    selection.setBaseAndExtent(fNode, fOffset, aNode, aOffset);
    selection.modify('extend', direction, granularity);
  }
}

function term_modifySideSelection() {
  var selection = document.getSelection();
  if (!selection || selection.rangeCount === 0) {
    return;
  }

  selection.setBaseAndExtent(
    selection.focusNode,
    selection.focusOffset,
    selection.anchorNode,
    selection.anchorOffset,
  );
}

function term_cleanSelection() {
  document.getSelection().removeAllRanges();
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

function term_setAutoCarriageReturn(state) {
  t.setAutoCarriageReturn(state);
}
