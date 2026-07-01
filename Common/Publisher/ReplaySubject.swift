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


private final class ShareReplayPublisher<Upstream: Publisher>: Publisher {
    typealias Output = Upstream.Output
    typealias Failure = Upstream.Failure

    private let upstream: Upstream
    private let subject: ReplaySubject<Output, Failure>
    private let lock = NSLock()
    private var connection: Cancellable?
    private var refCount = 0

    init(upstream: Upstream, maxValues: Int) {
        self.upstream = upstream
        self.subject = ReplaySubject<Output, Failure>(maxValues: maxValues)
    }

    func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
        lock.lock()
        let shouldConnect = (refCount == 0)
        refCount += 1

        if shouldConnect {
            connection = upstream
                .subscribe(subject)
        }
        lock.unlock()

        subject.subscribe(subscriber)
    }
}

extension Publisher {
    func shareReplay(maxValues: Int = 0) -> AnyPublisher<Output, Failure> {
        ShareReplayPublisher(upstream: self, maxValues: maxValues).eraseToAnyPublisher()
    }
}

final class ReplaySubject<Input, Failure: Error>: Subject {
    typealias Output = Input
    private var recording = Record<Input, Failure>.Recording()
    private let stream = PassthroughSubject<Input, Failure>()
    private let maxValues: Int
    private let lock = NSRecursiveLock()
    private var completed = false
  
    init(maxValues: Int = 0) {
        self.maxValues = maxValues
    }
    func send(subscription: Subscription) {
        subscription.request(maxValues == 0 ? .unlimited : .max(maxValues))
    }
    func send(_ value: Input) {
      lock.lock(); defer { lock.unlock() }
      guard !completed else { return }
        recording.receive(value)
        stream.send(value)
        if recording.output.count == maxValues {
            send(completion: .finished)
        }
    }
    func send(completion: Subscribers.Completion<Failure>) {
      lock.lock(); defer { lock.unlock() }
      guard !completed else { return }
      if !completed {
        completed = true
        recording.receive(completion: completion)
      }
      stream.send(completion: completion)
    }
    func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Input == S.Input {
      lock.lock(); defer { lock.unlock() }
        Record(recording: self.recording)
            .append(self.stream)
            .receive(subscriber: subscriber)
    }
}
