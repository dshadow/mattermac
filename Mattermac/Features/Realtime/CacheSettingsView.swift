import MattermacCore
import SwiftUI

struct CacheSettingsView: View {
  let persistence: AccountPersistence
  let activeChannelID: String?

  var body: some View {
    Form {
      Picker(
        "Keep cached messages",
        selection: Binding(
          get: { persistence.retentionDays },
          set: { days in
            Task { await persistence.updateRetention(days: days, activeChannelID: activeChannelID) }
          }
        )
      ) {
        Text("1 day").tag(1)
        Text("7 days").tag(7)
        Text("30 days").tag(30)
        Text("90 days").tag(90)
        Text("365 days").tag(365)
      }
      Text(
        "Inactive channel caches expire after their last access. Drafts and pending messages are kept until you sign out."
      )
      .foregroundStyle(.secondary)
      if let usage = persistence.usage {
        Text(
          "\(usage.records) cached records · \(ByteCountFormatter.string(fromByteCount: usage.physicalBytes, countStyle: .file)) on disk"
        )
      }
      if let notice = persistence.notice { Text(notice).foregroundStyle(.secondary) }
      Text(
        "Local databases rely on macOS permissions and your FileVault settings. They are not independently encrypted."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .task { await persistence.maintain(activeChannelID: activeChannelID) }
  }
}
