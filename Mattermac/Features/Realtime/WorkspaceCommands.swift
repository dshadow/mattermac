import SwiftUI

struct WorkspaceActions {
  var focusTeams: () -> Void
  var focusChannels: () -> Void
  var nextChannel: () -> Void
  var previousChannel: () -> Void
  var reconnect: () -> Void
}

private struct WorkspaceActionsKey: FocusedValueKey {
  typealias Value = WorkspaceActions
}

extension FocusedValues {
  var workspaceActions: WorkspaceActions? {
    get { self[WorkspaceActionsKey.self] }
    set { self[WorkspaceActionsKey.self] = newValue }
  }
}

struct WorkspaceCommands: Commands {
  @FocusedValue(\.workspaceActions) private var actions

  var body: some Commands {
    SidebarCommands()
    CommandMenu("Conversation") {
      Group {
        Button("Focus Teams") { actions?.focusTeams() }
          .keyboardShortcut("1", modifiers: [.command, .option])
        Button("Focus Channels") { actions?.focusChannels() }
          .keyboardShortcut("2", modifiers: [.command, .option])
        Divider()
        Button("Next Conversation") { actions?.nextChannel() }
          .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        Button("Previous Conversation") { actions?.previousChannel() }
          .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        Divider()
        Button("Reconnect") { actions?.reconnect() }
          .keyboardShortcut("r", modifiers: [.command, .option])
      }
      .disabled(actions == nil)
    }
  }
}
