import MattermacCore
import SwiftUI

struct WorkspaceView: View {
  let realtime: RealtimeSession
  let user: MattermostUser?
  let serverAddress: String
  @State private var selectedTeamID: String?
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @FocusState private var focus: WorkspaceFocus?

  private var channels: [MattermostChannel] {
    realtime.synchronization.channels.filter {
      $0.teamID == selectedTeamID || $0.type == "D" || $0.type == "G"
    }
  }

  private var selectedChannel: MattermostChannel? {
    channels.first { $0.id == realtime.synchronization.selectedChannelID }
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      VStack(spacing: 0) {
        List(selection: Binding(get: { selectedTeamID }, set: selectTeam)) {
          Section("Teams") {
            ForEach(realtime.navigation.teams) { team in
              HStack {
                Label(
                  team.displayName.isEmpty ? team.name : team.displayName, systemImage: "person.3"
                )
                .lineLimit(1)
                Spacer()
                if realtime.synchronization.channels.contains(where: {
                  $0.teamID == team.id && realtime.navigation.badges[$0.id]?.unread == true
                }) {
                  Image(systemName: "circle.fill").font(.system(size: 7))
                    .accessibilityLabel("Unread channels")
                }
              }
              .tag(team.id)
            }
          }
        }
        .listStyle(.sidebar)
        .focused($focus, equals: .teams)
        .accessibilityLabel("Teams")
        .overlay {
          if realtime.navigation.teams.isEmpty {
            if realtime.state == .connecting || realtime.state == .synchronizing {
              ProgressView("Loading teams…")
            } else {
              Text("No teams available").foregroundStyle(.secondary).padding()
            }
          }
        }
        Divider()
        VStack(alignment: .leading, spacing: 4) {
          Label(user?.username ?? "Signed in", systemImage: "person.crop.circle")
            .font(.headline).lineLimit(1)
          Text(serverAddress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
      }
      .navigationSplitViewColumnWidth(min: 140, ideal: 180, max: 260)
    } content: {
      List(
        selection: Binding(
          get: { selectedChannel?.id },
          set: { if let id = $0 { realtime.selectChannel(id) } })
      ) {
        ForEach(ChannelGroup.allCases, id: \.self) { group in
          let items = channels.filter { group.contains($0) }
          if !items.isEmpty {
            Section(group.rawValue) {
              ForEach(items) { channel in
                ChannelSidebarRow(
                  channel: channel,
                  title: realtime.navigation.title(for: channel, currentUserID: user?.id ?? ""),
                  badge: realtime.navigation.badges[channel.id]
                )
                .tag(channel.id)
              }
            }
          }
        }
      }
      .listStyle(.sidebar)
      .focused($focus, equals: .channels)
      .accessibilityLabel("Channels and conversations")
      .overlay {
        if channels.isEmpty {
          if realtime.state == .connecting || realtime.state == .synchronizing {
            ProgressView("Loading channels…")
          } else {
            ContentUnavailableView(
              "No channels", systemImage: "number",
              description: Text("Choose a team or join a channel on your Mattermost server."))
          }
        }
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
    } detail: {
      if let selectedChannel {
        VStack(spacing: 0) {
          HStack {
            Text(realtime.navigation.title(for: selectedChannel, currentUserID: user?.id ?? ""))
              .font(.title2).lineLimit(1)
            Spacer()
          }
          .padding()
          Divider()
          RealtimeView(realtime: realtime).padding()
        }
      } else {
        ContentUnavailableView(
          "Select a conversation", systemImage: "bubble.left.and.bubble.right",
          description: Text("Choose a channel or direct message from the sidebar."))
      }
    }
    .navigationTitle("Mattermac")
    .safeAreaInset(edge: .bottom) {
      HStack {
        if realtime.isLoadingNavigation { ProgressView().controlSize(.mini) }
        Text(realtime.state.rawValue)
        Spacer()
        if let message = realtime.navigationMessage ?? realtime.cacheMessage
          ?? realtime.storage?.notice
        {
          Text(message).lineLimit(2)
        }
      }
      .font(.caption).foregroundStyle(.secondary).padding(8)
    }
    .toolbar {
      Button("Reconnect", systemImage: "arrow.clockwise") { realtime.retry() }
    }
    .focusedSceneValue(
      \.workspaceActions,
      WorkspaceActions(
        focusTeams: {
          columnVisibility = .all
          focus = .teams
        },
        focusChannels: {
          columnVisibility = .all
          focus = .channels
        },
        nextChannel: { moveChannel(by: 1) }, previousChannel: { moveChannel(by: -1) },
        reconnect: { realtime.retry() })
    )
    .onChange(of: realtime.synchronization.selectedChannelID, initial: true) { _, _ in
      alignTeam()
    }
    .onChange(of: realtime.navigation.teams) { _, _ in alignTeam() }
  }

  private func alignTeam() {
    let teams = realtime.navigation.teams
    if let channel = realtime.synchronization.channels.first(where: {
      $0.id == realtime.synchronization.selectedChannelID
    }), teams.contains(where: { $0.id == channel.teamID }) {
      selectedTeamID = channel.teamID
    } else if !teams.contains(where: { $0.id == selectedTeamID }) {
      selectedTeamID = teams.first?.id
    }
  }

  private func selectTeam(_ id: String?) {
    guard let id, id != selectedTeamID else { return }
    selectedTeamID = id
    if let channel = realtime.synchronization.channels.first(where: { $0.teamID == id }) {
      realtime.selectChannel(channel.id)
    }
  }

  private func moveChannel(by offset: Int) {
    let ordered = ChannelGroup.allCases.flatMap { group in channels.filter { group.contains($0) } }
    guard !ordered.isEmpty else { return }
    let index =
      ordered.firstIndex { $0.id == selectedChannel?.id }
      ?? (offset > 0 ? -1 : 0)
    realtime.selectChannel(ordered[(index + offset + ordered.count) % ordered.count].id)
  }
}

private enum WorkspaceFocus: Hashable { case teams, channels }

private struct ChannelSidebarRow: View {
  let channel: MattermostChannel
  let title: String
  let badge: NavigationBadge?

  private var symbol: String {
    switch channel.type {
    case "P": "lock"
    case "D": "person"
    case "G": "person.2"
    default: "number"
    }
  }

  var body: some View {
    HStack {
      Label(title, systemImage: symbol).lineLimit(1)
        .fontWeight(badge?.unread == true ? .semibold : .regular)
      Spacer(minLength: 4)
      if let badge, badge.mentions > 0 {
        Text(badge.mentions.formatted()).font(.caption.bold())
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(.tint, in: Capsule()).foregroundStyle(.white)
          .accessibilityLabel("\(badge.mentions) mentions")
      } else if badge?.unread == true {
        Image(systemName: "circle.fill").font(.system(size: 7))
          .accessibilityLabel("Unread")
      }
    }
  }
}
