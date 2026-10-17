import MattermacCore
import SwiftUI

struct RealtimeView: View {
  let realtime: RealtimeSession

  var body: some View {
    MessageTimelineView(realtime: realtime)
      .id(realtime.synchronization.selectedChannelID)
  }
}
