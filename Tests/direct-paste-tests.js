// Exercise the production bridge with the bundled hterm paste implementation.
// Run with node Tests/direct-paste-tests.js. No app, network or clipboard access.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const resources = path.join(__dirname, '../Resources');
const bridge = fs.readFileSync(path.join(resources, 'term.js'), 'utf8');
const hterm = fs.readFileSync(path.join(resources, 'hterm_all.min.js'), 'utf8');
// The bundle exposes this synchronous method between two prototype assignments. Extracting it
// keeps this regression test tied to the version we actually ship, including sanitization.
const paste = hterm.match(/Terminal\.prototype\.onPaste_=(function\(e\)\{.*?\}),U\.Terminal\.prototype\.onCopy_/s);
assert.ok(paste, 'Locate the bundled hterm paste implementation');
const start = bridge.indexOf('function term_paste(');
const end = bridge.indexOf('var _moshroomDirectCursor', start);
assert.ok(start >= 0 && end > start);
const leaked = [];
const nativeWrite = bytes => leaked.push(bytes);
const terminal = {
  io: {sendString: nativeWrite},
  options_: {bracketedPaste: false},
  keyboard: {encode: text => text}, // The app configures hterm's raw UTF-8 encoding.
};
const context = vm.createContext({t: terminal});
terminal.onPaste_ = vm.runInContext(`(${paste[1]})`, context);
vm.runInContext(bridge.slice(start, end), context);
const prepare = text => JSON.parse(JSON.stringify(context.term_prepareDirectPaste(text)));
assert.deepEqual(prepare('á ñ 😀'), {bytes: 'á ñ 😀'});
for (const text of ['one\ntwo', 'one\rtwo', 'one\u2028two', 'one\u2029two']) {
  assert.deepEqual(prepare(text), {needsComposer: true});
}
terminal.options_.bracketedPaste = true;
assert.deepEqual(prepare('á😀\nnext'), {bytes: '\x1b[200~á😀\rnext\x1b[201~'});
for (const text of ['a\x1bb', 'a\0b', 'a\x7fb', 'a\x08b']) {
  assert.deepEqual(prepare(text), {needsComposer: true});
}
assert.deepEqual(leaked, [], 'Preparation must never write to the terminal');
assert.equal(terminal.io.sendString, nativeWrite, 'Restore the original output hook');
terminal.onPaste_ = function () { this.io.sendString('partial'); throw new Error('unavailable'); };
assert.throws(() => prepare('test'), /unavailable/);
assert.equal(terminal.io.sendString, nativeWrite, 'Restore output even if hterm throws');
assert.deepEqual(leaked, [], 'A failed preparation must not leak partial input');
context.t = null;
assert.deepEqual(prepare('test'), {unavailable: true});
console.log('Direct paste bridge: 18 assertions passed');
