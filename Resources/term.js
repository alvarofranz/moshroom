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

// The program set its window/terminal title via OSC 0/2 (claude, ssh, vim, tmux…). Keep
// document.title in sync AND push it to native so the terminal tab renames itself live — relying
// on WKWebView.title alone is unreliable for JS-driven title changes.
hterm.Terminal.prototype.setWindowTitle = function(title) {
  window.document.title = title;
  _postMessage('setTitle', {title: title || ''});
};

document.addEventListener('selectionchange', function() {
  _postMessage('selectionchange', term_getCurrentSelection());
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
  term_set('scroll-wheel-may-send-arrow-keys', true)
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
    // cursor transparent so the stray blue rectangle is gone. (The red text caret is a separate,
    // wanted thing — that's the contentEditable caret tinted with the Moshroom accent.)
    t.setCursorColor('rgba(0, 0, 0, 0)');

    // Moshroom: the terminal is a scroll + keys surface, not a document. Native text
    // selection hijacks the pan gesture (a swipe selects instead of scrolling, and the
    // selection cancels the scroll), so turn it off — a swipe scrolls / reports wheel to TUIs.
    var _moshroomScreen = t.scrollPort_.screen_;
    if (_moshroomScreen) {
      var _moshroomDoc = _moshroomScreen.ownerDocument;
      var _moshroomStyle = _moshroomDoc.createElement('style');
      // …plus a translucent Moshroom-red selection highlight (the grab handles follow the web
      // view's tintColor, also Moshroom red; this makes the highlight fill match instead of the
      // default black WebKit renders during a handle drag).
      _moshroomStyle.textContent = '*{-webkit-user-select:none!important;-webkit-touch-callout:none!important;caret-color:transparent!important;}::selection{background-color:rgba(203,31,41,0.45)!important;color:inherit!important;}';
      (_moshroomDoc.head || _moshroomDoc.documentElement).appendChild(_moshroomStyle);
    }

    // No text caret anywhere in the terminal — input happens in Moshkitor, so the blinking
    // insertion bar at the top-left is just a stray vestige. Hide it on the main document too.
    var _moshroomCaretStyle = document.createElement('style');
    _moshroomCaretStyle.textContent = '*{caret-color:transparent!important;}::selection{background-color:rgba(203,31,41,0.45)!important;color:inherit!important;}';
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
  var bytes = base64js.toByteArray(b64str); // b64_to_uint8_array(b64str);
  var data = _utf8TextDecoder.decode(bytes);
  t.interpret(data);
};

function b64_to_uint8_array(b64Str) {
  var s = atob(b64Str);
  var len = s.length;
  var res = new Uint8Array(len);
  for (var i = 0; i < len; i++) {
    res[i] = s.charCodeAt(i);
  }
  return res;
}

function term_clear() {
  t.clear();
}

function term_reset() {
  t.reset();
}

function term_focus() {
  t.onFocusChange__(true);
}

function term_blur() {
  t.onFocusChange__(false);
}

function _setTermCoordinates(event, x, y) {
  // One based row/column stored on the mouse event.
  var ty = (y / t.scrollPort_.characterSize.height | 0) + 1;
  var tx = (x / t.scrollPort_.characterSize.width | 0) + 1;
//  console.log(`x:${x},y: ${y}, col:${tx}, row:${ty}`);
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
  sel.removeAllRanges();
  sel.addRange(range);
  if (sel.modify) {
    sel.modify('move', 'backward', 'word');
    sel.modify('extend', 'forward', 'word');
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

function term_resetFontSize() {
  term_setFontSize();
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

function term_loadFontFromCss(url, name) {
  WebFont.load({
    custom: {
      families: [name],
      urls: [url],
    },
    active: function() {
      t.syncFontFamily();
    },
  });
  term_setFontFamily(name);
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

function term_restore() {
  t.primaryScreen_.textAttributes.reset();
  t.setVTScrollRegion(null, null);
  t.setCursorVisible(true);
}
