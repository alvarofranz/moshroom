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

import struct Network.IPv4Address
import struct Network.IPv6Address

enum SSHUtils {
  static func isValidIPv4(address: String) -> Bool {
    IPv4Address(address) != nil
  }
  
  static func isValidIPv6(address: String) -> Bool {
    IPv6Address(address) != nil
  }
  
  static func isValidIP(address: String) -> Bool {
    isValidIPv4(address: address) || isValidIPv6(address: address)
  }
}
