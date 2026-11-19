import AppKit
import FlutterMacOS

/// The Mac away from its user (the screen locked, the displays asleep, the Mac going to sleep, or another user's
/// session in front) reads to Dart as the app hidden, as a minimised window or a hidden app does. Flutter's engine
/// reports `hidden` from the app's occlusion alone, and macOS does not promise an occlusion change for each of these,
/// so this says it outright: work that runs only in the foreground (Private USD's key steps and polling, plan D9)
/// stops for them too.
///
/// It speaks the engine's own `flutter/lifecycle` messages. Once nothing keeps the Mac away it sends the state the
/// engine would report now (resumed while the app is active and visible, inactive while only visible, else hidden),
/// and again a moment later, since occlusion can trail an unlock. The engine's own messages still follow every
/// activation and occlusion change, so a wrong guess here lasts until the next one at most.
final class MacSessionLifecycle: NSObject {
  private enum Away: Hashable {
    case screenLocked
    case displaysAsleep
    case macAsleep
    case sessionInactive
  }

  private static let channel = "flutter/lifecycle"
  private static let hidden = "AppLifecycleState.hidden"
  private static let settleDelay: TimeInterval = 1
  private static let screenLocked = Notification.Name("com.apple.screenIsLocked")
  private static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

  private let messenger: FlutterBinaryMessenger
  private var away: Set<Away> = []
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var settle: DispatchWorkItem?

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
    let workspace = NSWorkspace.shared.notificationCenter
    observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.begin(.displaysAsleep) }
    observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.end(.displaysAsleep) }
    observe(workspace, NSWorkspace.willSleepNotification) { $0.begin(.macAsleep) }
    observe(workspace, NSWorkspace.didWakeNotification) { $0.end(.macAsleep) }
    observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.begin(.sessionInactive) }
    observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.end(.sessionInactive) }
    // An app that becomes active has its user back, whatever notification was missed on the way.
    observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { $0.endAll() }
    // Delivered at once even while the app is inactive: AppKit holds distributed notifications back otherwise.
    let distributed = DistributedNotificationCenter.default()
    distributed.addObserver(
      self,
      selector: #selector(screenDidLock),
      name: Self.screenLocked,
      object: nil,
      suspensionBehavior: .deliverImmediately
    )
    distributed.addObserver(
      self,
      selector: #selector(screenDidUnlock),
      name: Self.screenUnlocked,
      object: nil,
      suspensionBehavior: .deliverImmediately
    )
  }

  deinit {
    settle?.cancel()
    DistributedNotificationCenter.default().removeObserver(self)
    for (center, observer) in observers {
      center.removeObserver(observer)
    }
  }

  private func observe(
    _ center: NotificationCenter,
    _ name: Notification.Name,
    _ handle: @escaping (MacSessionLifecycle) -> Void
  ) {
    let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      guard let self else { return }
      handle(self)
    }
    observers.append((center, observer))
  }

  // Distributed notifications arrive on the main thread, the run loop the observer was added on.
  @objc private func screenDidLock(_ notification: Notification) {
    onMain { $0.begin(.screenLocked) }
  }

  @objc private func screenDidUnlock(_ notification: Notification) {
    onMain { $0.end(.screenLocked) }
  }

  private func onMain(_ handle: @escaping (MacSessionLifecycle) -> Void) {
    if Thread.isMainThread {
      handle(self)
    } else {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        handle(self)
      }
    }
  }

  private func begin(_ reason: Away) {
    away.insert(reason)
    settle?.cancel()
    settle = nil
    send(Self.hidden)
  }

  private func end(_ reason: Away) {
    guard away.remove(reason) != nil, away.isEmpty else { return }
    restore()
  }

  private func endAll() {
    guard !away.isEmpty else { return }
    away.removeAll()
    restore()
  }

  private func restore() {
    send(Self.currentState())
    settle?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.away.isEmpty else { return }
      self.send(Self.currentState())
    }
    settle = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
  }

  /// What Flutter's engine reports from the app's state: hidden unless a window shows, resumed while active.
  private static func currentState() -> String {
    if NSApp.isHidden || !NSApp.occlusionState.contains(.visible) { return hidden }
    return NSApp.isActive ? "AppLifecycleState.resumed" : "AppLifecycleState.inactive"
  }

  private func send(_ state: String) {
    messenger.send(onChannel: Self.channel, message: state.data(using: .utf8))
  }
}
