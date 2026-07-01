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

enum KBDevice {
  
  case in4   // iPhone4   // SE
  case in4_7 // iPhone4_7 // 6, 7, 8
  case in5_5 //
  case in5_8 // X, Xs, 12 Mini
  case in6_1 // iPhone 12 Pro
  case in6_5 // Xr!, Xs Max?         phone_5
  case in6_7
  
  case in9_7 // iPad Mini is the same
  case in10_2
  case in10_5
  case in10_9 // iPad Air 4 (2020)
  case in10_9_MoreSpace
  case in11
  case in11_MoreSpace
  case in12_9
  

  static func detect() -> Self {
    let size = UIScreen.main.bounds.size
    let wideSideSize = Int(max(size.height, size.width))
    
    // ZD  - Zoom Default
    // ZLT - Zoom Larger Text
    // ZMS - Zoom More Space
    //
    // checked devices lists
    // |  N | Device               |   ZD |  ZLT |  ZMS | tab |
    // +----+----------------------+------+------+------+-----|
    // |  1 | iPhone Mini 12       |  812 |  693 |      |     |
    // |  2 | iPhone 12            |  844 |  693 |      |     |
    // |  3 | iPhone 12 Pro        |  844 |  693 |      |     |
    // |  4 | iPhone 12 Pro Max    |  926 |  812 |      |     |
    // |  5 | iPhone 14            |  844 |  693 |      |     |
    // |  6 | iPhone 14 Plus       |  926 |  812 |      |     |
    // |  7 | iPhone 14 Pro        |  852 |  693 |      |     |
    // |  8 | iPhone 14 Pro Max    |  932 |  812 |      |     |
    // |  9 | iPhone SE 3d-gen     |  667 |  568 |      |     |
    // |    | iPhone 16 Pro        |  874 |  693 |      |     |
    // |    | iPhone 16 Pro Max    |  956 |  812 |      |     |
    // |    | iPhone 16e           |  844 |  693 |      |     |
    // | 10 | iPad 7th-gen         | 1080 |      |      |     |
    // | 11 | iPad 8th-gen         | 1080 |      |      |     |
    // | 12 | iPad 9th-gen         | 1180 |      |      |     |
    // | 13 | iPad Air 3th-gen     | 1112 |      |      |     |
    // | 14 | iPad Air 4th-gen     | 1180 |      |      | tab |
    // | 15 | iPad Air 5th-gen     | 1180 |      | 1373 | tab |
    // | 16 | iPad 10th-gen        | 1180 |      |      | tab | * TODO: remove tab key
    // | 17 | iPad mini 6th-gen    | 1133 |      |      |     |
    // | 18 | iPad Pro 11" 3d-gen  | 1194 |      | 1389 | tab |
    // | 18 | iPad Pro 11" 4d-gen  | 1194 |      | 1389 | tab |
    // | 19 | iPad Pro 12" 6th-gen | 1366 | 1024 | 1590 | tab |
    // | 20 | iPad Air 11" M2      | 1180 |      | 1373 | tab |
    // | 21 | iPad Air 13" M2      | 1366 | 1024 | 1590 | tab |
    // | 22 | iPad Pro 11" M4 17.4 | 1194 |      | 1408 | tab |
    // | 22 | iPad Pro 11" M4 17.5 | 1210 |      | 1408 | tab |
    // | 23 | iPad Pro 13" M4      | 1376 | 1032 | 1600 | tab |
    // | 23'| iPad Pro 13" M4 17.4 | 1366 | 1024 | 1590 | tab |
    // +----+----------------------+------+------+------+-----+
  
    switch wideSideSize {
    case 568:  return .in4
    case 667:  return .in4_7
    case 693:  return .in5_8 // iPhone 12 mini ZLT, iPhone 12 ZLT, iPhone 12 Pro ZLT
    case 736:  return .in5_5
    case 812:  return .in5_8 // iPhone 11 Pro, iPhone 12 Pro Max ZLT
    case 844:  return .in6_1 // iPhone 12 Pro, iPhone 14, iPhone 16e
    case 852:  return .in6_1 // iPhone 14 Pro
    case 874:  return .in6_1 // iPhone 16, iPhone 17, iPhone 17 Pro
    case 896:  return .in6_5 // iPhone 11 Pro Max
    case 912:  return .in6_7 // iPhone Air
    case 926:  return .in6_7 // iPhone 12 Pro Max, iPhone 14 Plus
    case 932:  return .in6_7 // iPhone 14 Pro Max
    case 956:  return .in6_7 // iPhone 16 Pro Max, iPhone 17 Pro Max
    case 1024, 1032:
      // tune for ipad 12 ZLT
      return DeviceInfo.shared().hasCorners ? .in12_9 : .in9_7 // iPad 12.9 ZLT
    case 1080: return .in10_2 // TODO: Tune for iPad 10th-gen
    // TODO: tune kb layout check real wideSizeSize instead of 1085
    case 1112: return .in10_5
    case 1133: return .in10_2 // iPad Mini 6th-gen. TODO: Tune for iPad mini
    case 1180:
      // iPad 9th-gen without cornders Airs 4 with corners
      return  DeviceInfo.shared().hasCorners ? .in10_9 : .in10_2
    case 1373: return .in10_9_MoreSpace
    case 1194: return .in11
    case 1389: return .in11_MoreSpace
    case 1366: return .in12_9
    case 1590: return .in12_9 // iPad 12.9 ZMS
    case 1210: return .in11
    case 1408: return .in11_MoreSpace
    case 1376: return .in12_9
    case 1600: return .in12_9
    default:
      // Safe fallback
      print("KBDevice: unknown device with size:", size)
      if UIDevice.current.userInterfaceIdiom == .pad {
        return .in9_7
      } else {
        return .in5_8
      }
    }
  }
    
}
