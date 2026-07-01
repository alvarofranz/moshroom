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


import UIKit

extension UIKit.NSCoder {
  
  func bk_encode(_ value: Any?, for key: CodingKey) {
    encode(value, forKey: key.stringValue)
  }
  
  func bk_decode<T>(for key: CodingKey) -> T? where T : NSObject, T : NSCoding {
    decodeObject(of: T.self, forKey: key.stringValue) as T?
  }
  
  func bk_decode<T>(of: [AnyClass], for key: CodingKey) -> T? {
    decodeObject(of: of, forKey: key.stringValue) as? T
  }
  
  // MARK: - Data
  
  func bk_encode(_ value: Data?, for key: CodingKey) {
    encode(value as NSData?, forKey: key.stringValue)
  }
  
  func bk_decode(for key: CodingKey) -> Data? {
    decodeObject(of: NSData.self, forKey: key.stringValue) as Data?
  }
  
  // MARK: - String
  
  func bk_encode(_ value: String?, for key: CodingKey) {
    encode(value, forKey: key.stringValue)
  }
  
  func bk_decode(for key: CodingKey) -> String? {
    decodeObject(of: NSString.self, forKey: key.stringValue) as String?
  }
  
  // MARK: - Bool
  
  func bk_encode(_ value: Bool, for key: CodingKey) {
    encode(value, forKey: key.stringValue)
  }
  
  func bk_decode(for key: CodingKey) -> Bool {
    decodeBool(forKey: key.stringValue)
  }
  
  // MARK: - Int
  
  func bk_encode(_ value: Int, for key: CodingKey) {
    encode(value, forKey: key.stringValue)
  }
  
  func bk_decode(for key: CodingKey) -> Int {
    decodeInteger(forKey: key.stringValue)
  }
  
  // MARK: - UInt
  
  func bk_encode(_ value: UInt, for key: CodingKey) {
    encode(Int(value), forKey: key.stringValue)
  }
  
  func bk_decode(for key: CodingKey) -> UInt {
    UInt(decodeInteger(forKey: key.stringValue))
  }
  
  // MARK: - CGRect
  
  func bk_encode(_ value: CGRect, for key: CodingKey) {
    bk_encode(NSCoder.string(for: value), for: key)
  }
  
  func bk_decode(for key: CodingKey) -> CGRect {
    NSCoder.cgRect(for: bk_decode(for: key) ?? "")
  }
  
  // MARK: - CGSize
  
  func bk_encode(_ value: CGSize, for key: CodingKey) {
    bk_encode(NSCoder.string(for: value), for: key)
  }

  func bk_decode(for key: CodingKey) -> CGSize {
    NSCoder.cgSize(for: bk_decode(for: key) ?? "")
  }
  
  // MARK: - CGPoint
  
  func bk_encode(_ value: CGPoint, for key: CodingKey) {
    bk_encode(NSCoder.string(for: value), for: key)
  }
  
  func bk_decode(for key: CodingKey) -> CGPoint {
    NSCoder.cgPoint(for: bk_decode(for: key) ?? "")
  }
  
}

