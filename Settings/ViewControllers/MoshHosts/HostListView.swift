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

import SwiftUI

fileprivate struct HostCard: Equatable {
  let host: MoshHosts
  let alias: String
  let hostName: String
  let hostDescription: String
  let user: String
  let projects: [String]
  init(host: MoshHosts) {
    self.host = host
    self.alias = host.host
    self.hostName = host.hostName
    self.hostDescription = host.hostDescription ?? ""
    self.user = host.user ?? ""
    self.projects = host.moshroomProjects.map { $0.name.isEmpty ? $0.session : $0.name }
  }

  /// `user@address`, the way it reads in a terminal.
  var target: String { user.isEmpty ? hostName : "\(user)@\(hostName)" }
}

/// One saved host as a card: the server glyph on a faint mushroom tile, the alias, its gray
/// description, `user@address` in monospace and, when it has any, its projects.
struct HostRow: View {
  fileprivate let card: HostCard

  var reloadList: () -> ()

  var body: some View {
    Row(
      content: {
        HStack(alignment: .top, spacing: 12) {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.moshTint.opacity(Double(Moshstyle.faintTintAlpha)))
            .frame(width: 38, height: 38)
            .overlay(
              Image(systemName: "server.rack")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.moshTint)
            )
          VStack(alignment: .leading, spacing: 3) {
            Text(card.alias)
              .font(.body.weight(.semibold))
              .foregroundColor(.primary)
              .lineLimit(1)
            if !card.hostDescription.isEmpty {
              Text(card.hostDescription)
                .font(.subheadline).foregroundColor(.secondary)
                .lineLimit(2)
            }
            Text(card.target)
              .font(.system(.footnote, design: .monospaced)).foregroundColor(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
            if !card.projects.isEmpty {
              HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundColor(.moshTint)
                Text(card.projects.count > 3
                     ? "\(card.projects.count) projects"
                     : card.projects.joined(separator: " \u{00B7} "))
                  .font(.footnote.weight(.medium))
                  .foregroundColor(.secondary)
                  .lineLimit(1)
              }
              .padding(.top, 2)
            }
          }
        }
        .padding(.vertical, 4)
      },
      details: {
        HostView(host: card.host, reloadList: reloadList)
      }
    )
  }
}

struct SortButton<T>: View where T: Equatable {
  let label: String
  @Binding var sortType: T
  let asc, desc: T
  
  var body: some View {
    Button {
      self.sortType = self.sortType == asc ? desc : asc
    } label: {
      HStack {
        Text(label)
        Spacer()
        if self.sortType == asc {
          Image(systemName: "chevron.up")
        } else if self.sortType == desc {
          Image(systemName: "chevron.down")
        }
      }
    }
  }
}

struct HostListView: View {
  @StateObject private var _state = HostsObservable()
  @EnvironmentObject private var _nav: Nav
  @State private var _pendingDelete: MoshDeletePrompt? = nil

  var body: some View {
    Group {
      if _state.list.isEmpty {
        MoshEmptyState(
          icon: "server.rack",
          title: "Your hosts",
          message: "Save a server once — alias, address, user and key — and connect from anywhere with one tap."
        ) {
          Button(action: _addHost) { Label("Add new Host", systemImage: "plus") }
        }
      } else {
        // One card per host (a section each, so every host reads as its own thing), the screen's
        // footer under the last one, and the docked search once the list is long enough to want it.
        VStack(spacing: 0) {
          List {
            ForEach(_state.filteredList, id: \.alias) { card in
              Section {
                HostRow(card: card, reloadList: _state.reloadHosts)
                  .contextMenu(menuItems: {
                    Button(action: {
                      _duplicateHost(card: card)
                    }, label: { Label("Duplicate", systemImage: "plus.square.on.square")})
                    Divider()
                    Button(role: .destructive, action: {
                      _confirmDelete(card)
                    }, label: { Label("Delete", systemImage: "trash") })
                  })
                  // Not a destructive role: that would take the row away before the user confirms.
                  .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { _confirmDelete(card) } label: { Label("Delete", systemImage: "trash") }
                      .tint(.moshTint)
                  }
              }
            }
            Section {
            } footer: {
              Text("A host is a server, saved once: address, user, key or password. Its projects are folders on it, each with its own session.")
            }
          }
          .listStyle(.insetGrouped)
          .listSectionSpacing(10)
          .overlay {
            if _state.filteredList.isEmpty {
              VStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 34)).foregroundColor(.secondary)
                Text("No matches").font(.headline).foregroundColor(.secondary)
              }
            }
          }

          if _state.list.count > 6 {
            MoshDockedSearch(query: $_state.filterQuery, prompt: "Search hosts and projects")
              .background(Color(.secondarySystemGroupedBackground))
              .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
              .padding(.horizontal, 16)
              .padding(.bottom, 10)
          }
        }
        .moshReadableWidth()
      }
    }
    .moshHubChromeBack(title: "Hosts") {
      if !_state.list.isEmpty {
        HStack(spacing: 8) {
          // Chip below, Menu on top with a clear label — Catalyst re-renders visible Menu labels.
          MoshNavGlyph(systemName: "list.bullet")
            .overlay(
              Menu {
                Section(header: Text("Order")) {
                  SortButton(label: "Alias",    sortType: $_state.sortType, asc: .aliasAsc, desc: .aliasDesc)
                  SortButton(label: "HostName", sortType: $_state.sortType, asc: .hostNameAsc, desc: .hostNameDesc)
                }
              } label: {
                Color.clear
                  .frame(width: MoshNavChip.diameter, height: MoshNavChip.diameter)
                  .contentShape(Rectangle())
              }
              .menuIndicator(.hidden)   // no system disclosure caret over the house chip
            )
          Button(action: _addHost, label: { MoshNavGlyph(systemName: "plus") })
        }
      }
    }
    // An iCloud pull can land while this screen is open — refresh so synced hosts appear live.
    .onReceive(NotificationCenter.default.publisher(for: HostsCloudMirror.didChangeNotification)) { _ in
      _state.reloadHosts()
    }
    .moshDeleteConfirmation($_pendingDelete)
  }
  
  // A deleted host is tombstoned, and the tombstone beats every other device's copy — this is the
  // gesture that can empty a server list you spent a year building, so it says so first.
  private func _confirmDelete(_ card: HostCard) {
    let projects = card.projects.count
    _pendingDelete = MoshDeletePrompt(
      name: card.alias,
      what: "this host",
      extra: projects == 0
        ? "Its address, user and connect settings go with it."
        : "Its address, user, connect settings and \(projects == 1 ? "its project" : "its \(projects) projects") go with it."
    ) {
      _state.deleteHosts([card])
    }
  }

  private func _addHost() {
    let rootView = HostView(host: nil, reloadList: _state.reloadHosts).environmentObject(_nav)
    let vc = UIHostingController(rootView: rootView)
    _nav.navController.pushViewController(vc, animated: true)
  }

  private func _duplicateHost(card: HostCard) {
    let rootView = HostView(duplicatingHost: card.host, reloadList:  _state.reloadHosts).environmentObject(_nav)
    let vc = UIHostingController(rootView: rootView)
    _nav.navController.pushViewController(vc, animated: true)
  }
}


fileprivate class HostsObservable: ObservableObject {
  enum HostSortType {
    case aliasAsc, aliasDesc, hostNameAsc, hostNameDesc
    
    var sortFn: (_ a: HostCard, _ b: HostCard) -> Bool {
      switch self {
      case .aliasAsc:     return { a, b in a.alias < b.alias }
      case .aliasDesc:    return { a, b in b.alias < a.alias }
      case .hostNameAsc:  return { a, b in a.hostName < b.hostName }
      case .hostNameDesc: return { a, b in b.hostName < a.hostName }
      }
    }
  }
  
  init() {
    filterIfNeeded()
  }
  
  @Published var filterQuery: String = "" {
    didSet {
      filterIfNeeded()
    }
  }
  
  @Published var sortType: HostSortType = .aliasAsc {
    didSet {
      list = list.sorted(by: sortType.sortFn)
      filterIfNeeded()
    }
  }
  
  @Published var filteredList: [HostCard] = []
  
  func filterIfNeeded() {
    let trimmedQuery = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedQuery.isEmpty {
      filteredList = list
      return
    }
    
    filteredList = list.filter({ h in
      h.hostName.localizedCaseInsensitiveContains(trimmedQuery) ||
      h.alias.localizedCaseInsensitiveContains(trimmedQuery) ||
      h.hostDescription.localizedCaseInsensitiveContains(trimmedQuery) ||
      h.projects.contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
    })
  }
  
  var list: [HostCard] = MoshHosts.allHosts()
    .map(HostCard.init(host:))
    .sorted(by: HostSortType.aliasAsc.sortFn)
  
  func reloadHosts() {
    self.list = MoshHosts.allHosts()
      .map(HostCard.init(host:))
      .sorted(by: sortType.sortFn)
    filterIfNeeded()
  }
  
  func deleteHosts(_ hostsToDelete: [HostCard]) {
    let allHosts = MoshHosts.all()
    for h in hostsToDelete {
      allHosts?.remove(h.host)
    }
    // The saved password goes with its host (the delete prompt already says it is gone everywhere),
    // but only once the list without the host is on disk, and never while another host still uses it.
    if MoshHosts.forceSave() {
      let stillUsed = Set(MoshHosts.allHosts().compactMap { $0.passwordRef }.filter { !$0.isEmpty })
      for h in hostsToDelete where !(h.host.passwordRef ?? "").isEmpty && !stillUsed.contains(h.host.passwordRef) {
        h.host.removePasswordFromKeychain()
      }
    }
    reloadHosts()
  }
}
