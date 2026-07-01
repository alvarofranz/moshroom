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


import Combine
import Foundation


public class MoshroomLogging {
  public typealias LogHandlerParameters = (Publishers.Share<AnyPublisher<[MoshroomLogKeys:Any], Never>>)
  public typealias LogHandlerFactory = ((LogHandlerParameters) throws -> AnyCancellable)
  fileprivate static var handlers = [LogHandlerFactory]()
  
  public static func handle(_ handler: @escaping LogHandlerFactory) {
    self.handlers.append(handler)
  }
  
  public static func reset() {
    self.handlers = []
  }
}

enum MoshroomLoggingHandlers {
  static func print(logPublisher: MoshroomLogging.LogHandlerParameters) -> AnyCancellable {
    logPublisher.filter(logLevel: .debug)
      .format { [
        "[\(Date().formatted(.iso8601))]",
        "[\($0[.logLevel] ?? MoshroomLogLevel.log)]",
        $0[.component] as? String ?? "global",
        $0[.message] as? String ?? ""
      ].joined(separator: " : ") }
      .sinkToOutput()
  }
}

// MoshroomLogging.handler { $0.map {}.sinkTo }
public struct MoshroomLogKeys: Hashable {
  private let rawValue: String
  
  static let message    = MoshroomLogKeys("message")
  static let logLevel   = MoshroomLogKeys("logLevel")
  static let component  = MoshroomLogKeys("component")
  
  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum MoshroomLogLevel: Int, Comparable, CustomStringConvertible {
  case trace
  case debug
  case info
  case warn
  case error
  case fatal
  // Skips or overrides.
  case log
  
  public static func < (lhs: MoshroomLogLevel, rhs: MoshroomLogLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
  
  public var description: String {
    switch self {
    case .trace: "TRACE"
    case .debug: "DEBUG"
    case .info: "INFO"
    case .warn: "WARN"
    case .error: "ERROR"
    case .fatal: "FATAL"
    case .log: "LOG"
    }
  }
}

class MoshroomLogger: Subject {
  typealias Output = [MoshroomLogKeys:Any]
  typealias Failure = Never
  
  private let sub = PassthroughSubject<Output, Never>()
  private var logger = Set<AnyCancellable>()

  public func send(_ value: Output) {
    sub.send(value)
  }
  
  func send(completion: Subscribers.Completion<Failure>) {
    sub.send(completion: completion)
  }
  
  func send(subscription: Subscription) {
    sub.send(subscription: subscription)
  }
  
  func receive<S>(subscriber: S) where S : Subscriber, Never == S.Failure, [MoshroomLogKeys : Any] == S.Input {
    sub.receive(subscriber: subscriber)
  }
  
  public init(bootstrap: ((AnyPublisher<Output, Never>) -> (AnyPublisher<Output, Never>))? = nil,
              handlers: [MoshroomLogging.LogHandlerFactory]? = nil) {
    var publisher = sub.eraseToAnyPublisher()
    if let bootstrap = bootstrap {
      publisher = bootstrap(publisher)
    }

    let handlers = handlers ?? MoshroomLogging.handlers
    handlers.forEach { handle in
      do {
        try handle(publisher.share()).store(in: &logger)
      } catch {
        Swift.print("Error initializing logging handler - \(error)")
      }
    }
  }
}

extension MoshroomLogger {
  public func send(_ message: String)   { self.send([.logLevel: MoshroomLogLevel.log,
                                                   .message: message,]) }

  public func trace(_ message: String)  { self.send([.logLevel: MoshroomLogLevel.trace,
                                                   .message: message,]) }
  public func debug(_ message: String)  { self.send([.logLevel: MoshroomLogLevel.debug,
                                                   .message: message,]) }
  public func info(_ message: String)   { self.send([.logLevel: MoshroomLogLevel.info,
                                                   .message: message,]) }
  public func warn(_ message: String)   { self.send([.logLevel: MoshroomLogLevel.warn,
                                                   .message: message,]) }
  public func error(_ message: String)  { self.send([.logLevel: MoshroomLogLevel.error,
                                                   .message: message,]) }
  public func fatal(_ message: String)  { self.send([.logLevel: MoshroomLogLevel.fatal,
                                                   .message: message,]) }
}

extension MoshroomLogger {
  convenience init(_ component: String,  
                   handlers: [MoshroomLogging.LogHandlerFactory]? = nil) {
    self.init(bootstrap: {
      $0.map { $0.merging([MoshroomLogKeys.component: component], uniquingKeysWith: { (_, new) in new }) }
        .eraseToAnyPublisher()
    }, handlers: handlers)
  }
}
