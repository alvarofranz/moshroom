// Copyright (C) 2026 Moshroom. Licensed under GPLv3; see COPYING.
// Run with Tests/run-direct-input-tests.sh. No app, network, user defaults or saved hosts.

import Foundation

@main enum DirectInputCoreTests {
  static var assertions = 0
  static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    precondition(condition(), message)
  }
  static func main() {
    var buffer = MoshroomInputBuffer()
    func change(_ text: String, marked: Int? = nil, expected: String, clears: Bool = false) {
      guard case .change(let delta) = buffer.update(text: text, markedStart: marked) else {
        preconditionFailure("Expected a committed change")
      }
      check(delta.bytes == expected, "Incorrect bytes for committed change")
      check(delta.clearAfterSending == clears, "Incorrect composition barrier")
      buffer.accept(delta)
    }
    change("a", expected: "a")
    change("á", expected: "\u{7f}á")
    change("á ñ 😀", expected: " ñ 😀")
    change("á ñ ", expected: "\u{7f}")
    buffer.reset()
    change("´", marked: 0, expected: "")
    change("á", expected: "á")
    check(buffer.sent == "á", "Accent should be committed exactly once")
    if case .composing = buffer.update(text: "á", markedStart: 0) {} else {
      preconditionFailure("Re-marking committed text must not delete it")
    }
    check(buffer.sent == "á", "Re-marking must preserve committed state")
    buffer.reset()
    change("한ㄱ", marked: 1, expected: "한")
    change("한국", expected: "국")
    buffer.reset()
    change("😀か", marked: 2, expected: "😀") // UIKit offsets are UTF-16, not Character counts.
    change("😀漢", expected: "漢")
    buffer.reset()
    change("👩‍💻", expected: "👩‍💻")
    if case .unsafeReplacement = buffer.update(text: "x", markedStart: nil) {} else {
      preconditionFailure("Cannot safely retract a ZWJ sequence in every terminal")
    }
    check(buffer.sent == "👩‍💻", "An unsent correction must not change committed state")
    buffer.reset()
    let long = String(repeating: "a", count: 256)
    change(long + "か", marked: 256, expected: long)
    check(buffer.sent.count == 256, "Buffer cap must leave an active IME composition intact")
    change(long + "漢", expected: "漢", clears: true)
    check(buffer.sent.isEmpty, "A completed long composition should establish a barrier")
    change("next\n", expected: "next\r", clears: true)
    change("fresh", expected: "fresh")
    buffer.reset()
    change("é", expected: "é")
    change("e\u{301}", expected: "\u{7f}e\u{301}") // Equal graphemes can contain different bytes.

    let queue = MoshroomInputQueue()
    var allowed = true
    var writes: [String] = []
    var requests: [(String, (Result<String, MoshroomInputQueue.Failure>) -> Void)] = []
    var failures: [MoshroomInputQueue.Failure] = []
    queue.isAllowed = { allowed }
    queue.write = { writes.append($0) }
    queue.preparePaste = { requests.append(($0, $1)) }
    queue.onFailure = { _, error in failures.append(error) }
    queue.send("a")
    queue.paste("pasted")
    queue.send("b")
    queue.paste("second")
    queue.send("c")
    check(writes == ["a"], "Keys must wait for the paste")
    requests[0].1(.success("[pasted]"))
    check(writes == ["a", "[pasted]", "b"], "First paste must keep FIFO order")
    check(requests.count == 2, "Second paste must prepare only after first finishes")
    requests[0].1(.success("duplicate"))
    check(writes.count == 3, "A duplicate callback must not resolve the next paste")
    requests[1].1(.success("[second]"))
    check(writes == ["a", "[pasted]", "b", "[second]", "c"], "All input must retain order")
    queue.paste("stale")
    queue.send("discard")
    queue.cancel() // tab / window / modal transition
    queue.paste("new tab")
    requests[2].1(.success("must never reach new tab"))
    check(writes.count == 5, "Old callback must not write into the new generation")
    requests[3].1(.success("new tab"))
    check(writes.last == "new tab", "New generation must remain usable")
    queue.paste("lost focus")
    queue.send("discard")
    allowed = false
    requests[4].1(.success("blocked"))
    check(writes.last == "new tab", "Modal/focus gate must be checked at delivery")
    check(!queue.send("blocked"), "Rejected bytes must not advance the text buffer")
    allowed = true
    queue.paste("unsafe multiline")
    queue.send("discard")
    requests[5].1(.failure(.needsComposer))
    check(failures.count == 1 && writes.last == "new tab", "A failed paste must cancel queued keys")
    queue.paste("timeout")
    queue.send("cannot overtake")
    RunLoop.main.run(until: Date().addingTimeInterval(2.15))
    check(failures.count == 2 && writes.last == "new tab", "A timeout must not release queued keys")
    requests[6].1(.success("late"))
    check(writes.last == "new tab", "A timed-out evaluation must remain inert")
    queue.send("recovered")
    check(writes.last == "recovered", "Input must recover after a failed paste")
    queue.write = { bytes in
      writes.append(bytes)
      if bytes == "switch owner" {
        queue.cancel()
        queue.paste("replacement owner")
      }
    }
    queue.paste("switch owner")
    queue.send("old owner's queued key")
    requests[7].1(.success("switch owner"))
    requests[8].1(.success("replacement owner"))
    check(writes.last == "replacement owner", "Reentrant ownership changes must retain the new paste")
    check(!writes.contains("old owner's queued key"), "Ownership changes must cancel the old queue")
    queue.write = { _ in } // Release the test closure's reference back to the queue.
    print("Direct input core: \(assertions) assertions passed")
  }
}
