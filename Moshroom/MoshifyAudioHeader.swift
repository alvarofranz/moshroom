////////////////////////////////////////////////////////////////////////////////
//
// M O S H R O O M
//
// Copyright (C) 2026 Moshroom
//
// This file is part of Moshroom.
//
// Moshroom is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Moshroom is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Moshroom. If not, see <http://www.gnu.org/licenses/>.
//
////////////////////////////////////////////////////////////////////////////////

import Foundation

/// How long a track is, read from the FIRST bytes of the file.
///
/// Why this exists: a remote listing (SFTP readdir/stat) gives a name, a size and a date, and
/// nothing else — the length lives inside the audio itself. The alternatives were asking the server
/// to tell us (ffprobe over ssh: a tool Moshroom refuses to require) or downloading whole tracks
/// just to look at them. So the app reads a small head of the file over the SFTP connection it
/// already has and parses the container here, on the device, with no dependency of any kind.
///
/// The rule throughout: return a length only when the bytes SAY it. Nothing here estimates from
/// "average bitrate" — a wrong time next to a track is worse than no time at all. What is exact:
/// FLAC and WAV always, MP4/M4A whenever its `moov` sits at the front (Apple's own encoders and
/// most others put it there), MP3 with a Xing/Info frame count or genuinely constant bitrate.
/// Ogg-Opus is the one that cannot be done from the head — its length is the granule position of
/// the LAST page — and it needs no parser anyway: those tracks are transcoded when they land and
/// report their length exactly from then on.
enum MoshifyAudioHeader {

  /// `head` should be the first few kilobytes (32 KB is plenty); `totalSize` is the file's size from
  /// the listing, which some formats need to finish the arithmetic.
  static func duration(head: Data, fileName: String, totalSize: UInt64) -> TimeInterval? {
    switch (fileName as NSString).pathExtension.lowercased() {
    case "flac":               return flac(head)
    case "wav", "wave":        return wav(head)
    case "m4a", "mp4", "aac":  return mp4(head)
    case "mp3":                return mp3(head, totalSize: totalSize)
    case "aiff", "aif":        return aiff(head)
    default:                   return nil
    }
  }

  /// Is a second read, of the END of the file, worth a round trip? Two formats keep what we need
  /// back there: an MP4 whose `moov` trails the audio (ffmpeg's default layout, and plenty of
  /// libraries are full of them), and Ogg-Opus, whose length IS the granule position of its last
  /// page. `head` is what a first read already answered — nil means it did not.
  static func wantsTail(fileName: String, headAnswer: TimeInterval?) -> Bool {
    switch (fileName as NSString).pathExtension.lowercased() {
    case "opus", "ogg", "oga":  return true
    case "m4a", "mp4", "aac":   return headAnswer == nil
    default:                    return false
    }
  }

  /// With both ends of the file in hand. Same rule as ever: only what the bytes state.
  static func duration(head: Data, tail: Data, fileName: String, totalSize: UInt64) -> TimeInterval? {
    if let answer = duration(head: head, fileName: fileName, totalSize: totalSize) { return answer }
    switch (fileName as NSString).pathExtension.lowercased() {
    case "opus", "ogg", "oga":  return ogg(head: head, tail: tail)
    case "m4a", "mp4", "aac":   return mp4Tail(tail)
    default:                    return nil
    }
  }

  // MARK: - MP4 with a trailing moov

  /// The tail buffer starts mid-file, so the atom chain cannot be walked from a boundary: find the
  /// `moov`/`mvhd` markers directly and validate what they claim (a timescale and a length that
  /// could belong to real audio), so a chance match inside compressed data cannot invent a time.
  private static func mp4Tail(_ d: Data) -> TimeInterval? {
    guard let mvhd = find(Array("mvhd".utf8), in: d) else { return nil }
    let p = mvhd + 4                      // payload: version+flags, then the times
    guard p + 20 <= d.count else { return nil }
    let version = d[p]
    let timescale: UInt32
    let duration: UInt64
    if version == 1 {
      guard p + 28 <= d.count else { return nil }
      timescale = be32(d, p + 20)
      duration = be64(d, p + 24)
    } else {
      timescale = be32(d, p + 12)
      duration = UInt64(be32(d, p + 16))
    }
    guard timescale >= 1, timescale <= 10_000_000, duration > 0 else { return nil }
    let seconds = Double(duration) / Double(timescale)
    guard seconds > 0, seconds < 24 * 3600 else { return nil }
    return seconds
  }

  // MARK: - Ogg (Opus)

  /// An Ogg stream's length is the granule position of its LAST page: for Opus that counts 48 kHz
  /// samples, including the encoder's pre-skip, which the OpusHead in the first page states.
  private static func ogg(head: Data, tail: Data) -> TimeInterval? {
    guard let lastGranule = lastOggGranule(tail) else { return nil }
    let preSkip = opusPreSkip(head) ?? 0
    let samples = lastGranule > UInt64(preSkip) ? lastGranule - UInt64(preSkip) : lastGranule
    let seconds = Double(samples) / 48_000
    guard seconds > 0, seconds < 24 * 3600 else { return nil }
    return seconds
  }

  private static func lastOggGranule(_ d: Data) -> UInt64? {
    let magic = Array("OggS".utf8)
    var found: UInt64?
    var i = d.startIndex
    while let at = find(magic, in: d, from: i) {
      if at + 14 <= d.count {
        var g: UInt64 = 0
        for k in (0..<8).reversed() { g = (g << 8) | UInt64(d[at + 6 + k]) }   // little-endian
        if g != UInt64.max { found = g }                                       // -1 = "no packet ends here"
      }
      i = at + 4
    }
    return found
  }

  /// The pre-skip field of an OpusHead packet ("OpusHead" then version, channels, pre-skip LE16).
  private static func opusPreSkip(_ d: Data) -> Int? {
    guard let at = find(Array("OpusHead".utf8), in: d), at + 12 <= d.count else { return nil }
    return Int(UInt16(d[at + 10]) | UInt16(d[at + 11]) << 8)
  }

  /// First index of `needle` in `d` at or after `from`.
  private static func find(_ needle: [UInt8], in d: Data, from: Int = 0) -> Int? {
    guard needle.count <= d.count else { return nil }
    let last = d.count - needle.count
    var i = max(0, from)
    while i <= last {
      if d[i] == needle[0] {
        var k = 1
        while k < needle.count, d[i + k] == needle[k] { k += 1 }
        if k == needle.count { return i }
      }
      i += 1
    }
    return nil
  }

  // MARK: - FLAC

  /// "fLaC" then metadata blocks; STREAMINFO is always the first one and carries the sample rate
  /// (20 bits) and the total sample count (36 bits) at a fixed offset.
  private static func flac(_ d: Data) -> TimeInterval? {
    guard d.count >= 26, d[0...3].elementsEqual(Array("fLaC".utf8)) else { return nil }
    let b = [UInt8](d[8..<26])
    let rate = (UInt32(b[10]) << 12) | (UInt32(b[11]) << 4) | (UInt32(b[12]) >> 4)
    let samples =
      (UInt64(b[13] & 0x0F) << 32) | (UInt64(b[14]) << 24) |
      (UInt64(b[15]) << 16) | (UInt64(b[16]) << 8) | UInt64(b[17])
    guard rate > 0, samples > 0 else { return nil }
    return Double(samples) / Double(rate)
  }

  // MARK: - WAV

  /// RIFF/WAVE: walk the chunks for `fmt ` (byte rate) and `data` (its size).
  private static func wav(_ d: Data) -> TimeInterval? {
    guard d.count > 44, d[0...3].elementsEqual(Array("RIFF".utf8)),
          d[8...11].elementsEqual(Array("WAVE".utf8)) else { return nil }
    var i = 12
    var byteRate: UInt32 = 0
    while i + 8 <= d.count {
      let id = String(bytes: d[i..<(i + 4)], encoding: .ascii) ?? ""
      let size = le32(d, i + 4)
      if id == "fmt ", i + 8 + 16 <= d.count {
        byteRate = le32(d, i + 8 + 8)
      } else if id == "data" {
        guard byteRate > 0, size > 0 else { return nil }
        return Double(size) / Double(byteRate)
      }
      i += 8 + Int(size) + (Int(size) % 2)   // chunks are word-aligned
      if size == 0 { break }
    }
    return nil
  }

  // MARK: - MP4 / M4A

  /// Walk the top-level atoms for `moov`, then its `mvhd`, whose duration/timescale is the answer.
  /// A file whose `moov` trails the audio (some encoders) simply returns nil from a head read.
  private static func mp4(_ d: Data) -> TimeInterval? {
    guard let moov = atom(named: "moov", in: d, from: 0, to: d.count) else { return nil }
    guard let mvhd = atom(named: "mvhd", in: d, from: moov.lowerBound, to: moov.upperBound) else { return nil }
    let p = mvhd.lowerBound            // payload start
    guard p + 4 <= d.count else { return nil }
    let version = d[p]
    if version == 1 {
      guard p + 28 <= d.count else { return nil }
      let timescale = be32(d, p + 20)
      let duration = be64(d, p + 24)
      guard timescale > 0 else { return nil }
      return Double(duration) / Double(timescale)
    }
    guard p + 20 <= d.count else { return nil }
    let timescale = be32(d, p + 12)
    let duration = be32(d, p + 16)
    guard timescale > 0, duration > 0 else { return nil }
    return Double(duration) / Double(timescale)
  }

  /// The payload range of the first atom with this name between `from` and `to`, searching one level
  /// and (for containers) recursing into it.
  private static func atom(named name: String, in d: Data, from: Int, to: Int) -> Range<Int>? {
    var i = from
    while i + 8 <= min(to, d.count) {
      var size = Int(be32(d, i))
      let type = String(bytes: d[(i + 4)..<(i + 8)], encoding: .ascii) ?? ""
      var payload = i + 8
      if size == 1 {                              // 64-bit size
        guard i + 16 <= d.count else { return nil }
        size = Int(be64(d, i + 8))
        payload = i + 16
      } else if size == 0 {                       // "to the end of the file"
        size = min(to, d.count) - i
      }
      guard size >= 8 else { return nil }
      if type == name { return payload..<min(i + size, d.count) }
      i += size
    }
    return nil
  }

  // MARK: - AIFF

  /// FORM/AIFF: the COMM chunk carries the frame count and the sample rate as an 80-bit float.
  private static func aiff(_ d: Data) -> TimeInterval? {
    guard d.count > 12, d[0...3].elementsEqual(Array("FORM".utf8)),
          d[8...11].elementsEqual(Array("AIFF".utf8)) || d[8...11].elementsEqual(Array("AIFC".utf8))
    else { return nil }
    var i = 12
    while i + 8 <= d.count {
      let id = String(bytes: d[i..<(i + 4)], encoding: .ascii) ?? ""
      let size = Int(be32(d, i + 4))
      if id == "COMM", i + 8 + 18 <= d.count {
        let frames = be32(d, i + 8 + 2)
        let rate = extended80(d, i + 8 + 8)
        guard frames > 0, rate > 0 else { return nil }
        return Double(frames) / rate
      }
      guard size > 0 else { break }
      i += 8 + size + (size % 2)
    }
    return nil
  }

  /// The 80-bit IEEE extended float AIFF uses for its sample rate.
  private static func extended80(_ d: Data, _ at: Int) -> Double {
    guard at + 10 <= d.count else { return 0 }
    let exponent = Int((UInt16(d[at]) << 8 | UInt16(d[at + 1])) & 0x7FFF)
    var mantissa: UInt64 = 0
    for k in 0..<8 { mantissa = (mantissa << 8) | UInt64(d[at + 2 + k]) }
    guard exponent != 0 else { return 0 }
    let sign: Double = (d[at] & 0x80) != 0 ? -1 : 1
    return sign * Double(mantissa) * pow(2.0, Double(exponent - 16383 - 63))
  }

  // MARK: - MP3

  /// Skip any ID3v2 tag, find the first frame, and take the length from the Xing/Info frame count
  /// when it is there. Without it, only a CBR file can be measured honestly: bitrate and size say
  /// everything, and a VBR file without a Xing header returns nil rather than a plausible lie.
  private static func mp3(_ d: Data, totalSize: UInt64) -> TimeInterval? {
    var start = 0
    if d.count > 10, d[0...2].elementsEqual(Array("ID3".utf8)) {
      let tag = (Int(d[6]) << 21) | (Int(d[7]) << 14) | (Int(d[8]) << 7) | Int(d[9])
      start = 10 + tag
      if (d[5] & 0x10) != 0 { start += 10 }   // footer
    }
    guard let frame = frameHeader(d, from: start) else { return nil }
    let audioBytes = totalSize > UInt64(frame.offset) ? totalSize - UInt64(frame.offset) : 0

    // Xing ("Xing"/"Info") sits inside the first frame, after the side information.
    let sideInfo = frame.channels == 1 ? 17 : 32
    let xing = frame.offset + 4 + sideInfo
    if xing + 12 <= d.count {
      let tag = String(bytes: d[xing..<(xing + 4)], encoding: .ascii) ?? ""
      if tag == "Xing" || tag == "Info" {
        let flags = be32(d, xing + 4)
        if flags & 0x1 != 0 {
          let frames = be64Frames(d, xing + 8)
          if frames > 0, frame.sampleRate > 0 {
            return Double(frames) * Double(frame.samplesPerFrame) / Double(frame.sampleRate)
          }
        }
      }
    }
    // No Xing: trust the bitrate only when the next frame header agrees with it (constant bitrate).
    guard let next = frameHeader(d, from: frame.offset + frame.frameLength),
          next.bitrate == frame.bitrate, frame.bitrate > 0, audioBytes > 0
    else { return nil }
    return Double(audioBytes) * 8 / Double(frame.bitrate)
  }

  private struct Mp3Frame {
    let offset: Int
    let bitrate: Int          // bits per second
    let sampleRate: Int
    let channels: Int
    let samplesPerFrame: Int
    let frameLength: Int
  }

  private static let mp3Bitrates: [[Int]] = [
    // MPEG1 Layer III
    [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0],
    // MPEG2/2.5 Layer III
    [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0],
  ]
  private static let mp3Rates: [[Int]] = [
    [44100, 48000, 32000],   // MPEG1
    [22050, 24000, 16000],   // MPEG2
    [11025, 12000, 8000],    // MPEG2.5
  ]

  /// The first valid Layer III frame header at or after `from`.
  private static func frameHeader(_ d: Data, from: Int) -> Mp3Frame? {
    var i = max(0, from)
    let limit = min(d.count - 4, i + 8192)     // a frame starts near where we looked, or not at all
    while i <= limit {
      defer { i += 1 }
      guard d[i] == 0xFF, (d[i + 1] & 0xE0) == 0xE0 else { continue }
      let versionBits = (d[i + 1] >> 3) & 0x03
      let layerBits = (d[i + 1] >> 1) & 0x03
      guard layerBits == 0x01 else { continue }            // Layer III only
      let rateIndex: Int
      let bitrateTable: Int
      let samplesPerFrame: Int
      switch versionBits {
      case 0x03: rateIndex = 0; bitrateTable = 0; samplesPerFrame = 1152   // MPEG1
      case 0x02: rateIndex = 1; bitrateTable = 1; samplesPerFrame = 576    // MPEG2
      case 0x00: rateIndex = 2; bitrateTable = 1; samplesPerFrame = 576    // MPEG2.5
      default: continue                                                    // reserved
      }
      let bitrateIndex = Int((d[i + 2] >> 4) & 0x0F)
      let sampleIndex = Int((d[i + 2] >> 2) & 0x03)
      guard bitrateIndex > 0, bitrateIndex < 15, sampleIndex < 3 else { continue }
      let bitrate = mp3Bitrates[bitrateTable][bitrateIndex] * 1000
      let sampleRate = mp3Rates[rateIndex][sampleIndex]
      guard bitrate > 0, sampleRate > 0 else { continue }
      let padding = Int((d[i + 2] >> 1) & 0x01)
      let channels = ((d[i + 3] >> 6) & 0x03) == 0x03 ? 1 : 2
      let frameLength = samplesPerFrame / 8 * bitrate / sampleRate + padding
      return Mp3Frame(offset: i, bitrate: bitrate, sampleRate: sampleRate, channels: channels,
                      samplesPerFrame: samplesPerFrame, frameLength: max(frameLength, 4))
    }
    return nil
  }

  // MARK: - byte helpers

  private static func le32(_ d: Data, _ at: Int) -> UInt32 {
    guard at + 4 <= d.count else { return 0 }
    return UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
  }
  private static func be32(_ d: Data, _ at: Int) -> UInt32 {
    guard at + 4 <= d.count else { return 0 }
    return UInt32(d[at]) << 24 | UInt32(d[at + 1]) << 16 | UInt32(d[at + 2]) << 8 | UInt32(d[at + 3])
  }
  private static func be64(_ d: Data, _ at: Int) -> UInt64 {
    guard at + 8 <= d.count else { return 0 }
    var v: UInt64 = 0
    for k in 0..<8 { v = (v << 8) | UInt64(d[at + k]) }
    return v
  }
  private static func be64Frames(_ d: Data, _ at: Int) -> UInt64 { UInt64(be32(d, at)) }
}
