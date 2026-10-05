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

import Dispatch
import Foundation
import Combine


public enum DispatchStreamError: Error {
  case read(msg: String)
  case write(msg: String)
  public var description: String {
    switch self {
    case .read(let msg):
      return "Read Error: \(msg)"
    case .write(let msg):
      return "Write Error: \(msg)"
    }
  }
}

/// The cleanup handler for a stream's channel. DispatchIO runs it exactly once, after the channel
/// is closed (by `close()` or on deinit) and every pending operation has drained, which is the one
/// safe moment to close the descriptor. Only a descriptor the stream OWNS is closed: a caller that
/// hands in a dup() passes `closesDescriptor: true`, while a caller that keeps using its descriptor
/// (or closes it itself) keeps the default.
fileprivate func dispatchStreamCleanup(_ fd: Int32, owned: Bool) -> (Int32) -> Void {
  guard owned, fd >= 0 else { return { _ in } }
  return { _ in Darwin.close(fd) }
}

public class DispatchOutputStream: Writer {
  let stream: DispatchIO
  let queue: DispatchQueue
  var fd: Int32?
  
  public init(stream: Int32, closesDescriptor: Bool = false) {
    self.fd = stream
    self.queue = DispatchQueue(label: "file-\(stream)")
    self.stream = DispatchIO(type: .stream, fileDescriptor: stream, queue: self.queue,
                             cleanupHandler: dispatchStreamCleanup(stream, owned: closesDescriptor))
    self.stream.setLimit(lowWater: 0)
  }
  
  public func write(_ buf: DispatchData, max length: Int) -> AnyPublisher<Int, Error> {
    let pub = PassthroughSubject<Int, Error>()
    
    return pub.handleEvents(receiveRequest: { _ in
      self.stream.write(offset: 0, data: buf, queue: self.queue) { (done, bytes, error) in
        if error == POSIXErrorCode.ECANCELED.rawValue {
          return pub.send(completion: .finished)
        }
        
        if error != 0 {
          pub.send(completion: .failure(DispatchStreamError.write(msg: String(validatingUTF8: strerror(errno)) ?? "")))
          return
        }
        
        if done {
          pub.send(length)
          pub.send(completion: .finished)
        }
      }
    }).eraseToAnyPublisher()
  }
  
  public func close() {
    if self.fd != nil {
      stream.close(flags: .stop)
      self.fd = nil
    }
  }
  
  deinit {
    if self.fd != nil {
      stream.close(flags: .stop)
    }
  }
}

public class DispatchInputStream {
  let stream: DispatchIO
  let queue: DispatchQueue
  var fd: Int32?
  
  public init(stream: Int32, closesDescriptor: Bool = false) {
    self.fd = stream
    self.queue = DispatchQueue(label: "file-\(stream)")
    self.stream = DispatchIO(type: .stream, fileDescriptor: stream, queue: self.queue,
                             cleanupHandler: dispatchStreamCleanup(stream, owned: closesDescriptor))
    self.stream.setLimit(lowWater: 0)
  }
  
  public func close() {
    if self.fd != nil {
      stream.close(flags: .stop)
      self.fd = nil
    }
  }
  
  deinit {
    if self.fd != nil {
      stream.close(flags: .stop)
    }
  }
}


// Create DispatchStreams, reader and writers that we can use for this scenarios.
extension DispatchInputStream: WriterTo {
  public func writeTo(_ w: Writer) -> AnyPublisher<Int, Error> {
    let pub = PassthroughSubject<DispatchData, Error>()
    
    return pub.handleEvents(receiveRequest: { _ in
      self.stream.read(offset: 0, length: Int(UINT32_MAX), queue: self.queue) { (done, data, error) in
        if error == POSIXErrorCode.ECANCELED.rawValue {
          return pub.send(completion: .finished)
        }
        
        if error != 0 {
          pub.send(completion: .failure(DispatchStreamError.read(msg: String(validatingUTF8: strerror(errno)) ?? "")))
          return
        }
        
        guard let data = data else {
          return assertionFailure()
        }
        let eof = done && data.count == 0
        guard !eof else {
          return pub.send(completion: .finished)
        }
        
        pub.send(data)
        
        if done {
          return pub.send(completion: .finished)
        }
      }
    })
    .flatMap { data in
      return w.write(data, max: data.count)
    }.eraseToAnyPublisher()
  }
}
