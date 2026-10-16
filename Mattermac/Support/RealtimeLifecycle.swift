import AppKit
import MattermacCore
import Network

/// App-wide hooks, independent of window count and scene activation.
@MainActor final class RealtimeLifecycle: NSObject, NSApplicationDelegate {
  private var realtime: RealtimeSession?
  private var monitor: NWPathMonitor?
  private var observers: [NSObjectProtocol] = []

  func start(_ realtime: RealtimeSession?) {
    guard monitor == nil, let realtime else { return }
    self.realtime = realtime
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in self?.realtime?.suspend() }
      })
    observers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in self?.realtime?.resume() }
      })
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let available = path.status == .satisfied
      Task { @MainActor in
        // Address/route changes can occur without changing the interface type or index.
        self?.realtime?.networkChanged(available: available)
      }
    }
    self.monitor = monitor
    monitor.start(queue: DispatchQueue(label: "Mattermac.NetworkPath"))
  }

  func applicationWillTerminate(_ notification: Notification) {
    realtime?.stop()
    monitor?.cancel()
    for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    observers = []
  }
}
