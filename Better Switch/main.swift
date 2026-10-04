import AppKit
import ApplicationServices
import OSLog
import ServiceManagement
@preconcurrency import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
  private static let enabledKey = "betterSwitchEnabled"
  private static let shakeCooldown: TimeInterval = 1.2

  private let logger = Logger(subsystem: "com.parussoft.Better-Switch", category: "App")
  private let windowRestorer = WindowRestorer()
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  private var statusItem: NSStatusItem!
  private var enabledItem: NSMenuItem!
  private var restoreShakeItem: NSMenuItem!
  private var launchAtLoginItem: NSMenuItem!
  private var accessibilityItem: NSMenuItem!
  private var grantAccessibilityItem: NSMenuItem!
  private var workspaceObserver: NSObjectProtocol?
  private var pendingActivationCheck: DispatchWorkItem?
  private var isEnabled = true
  private var pendingFocusChecks: [DispatchWorkItem] = []
  private var pendingFocusConfirmation: DispatchWorkItem?
  private var windowAwaitingConfirmation: AXUIElement?
  private var mouseMonitor: Any?
  private var draggedWindow: AXUIElement?
  private var draggedWindowSize = CGSize.zero
  private var shakeSamples: [(time: TimeInterval, x: CGFloat)] = []
  private var shakeReadyAt: TimeInterval = 0
  private var hiddenApplications: [NSRunningApplication] = []
  private var minimizedWindows: [AXUIElement] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    UserDefaults.standard.register(defaults: [Self.enabledKey: true])
    isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)

    configureStatusItem()
    observeApplicationActivation()
    observeMouseDragging()
    logger.info("Better Switch started. Enabled: \(self.isEnabled, privacy: .public)")

    if !AXIsProcessTrusted() {
      requestAccessibilityPermission()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    pendingActivationCheck?.cancel()
    cancelFocusChecks()
    if let mouseMonitor {
      NSEvent.removeMonitor(mouseMonitor)
    }
    restoreShakenWindows()
    if let workspaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
    }
  }

  func menuWillOpen(_ menu: NSMenu) {
    refreshMenu()
  }

  private func configureStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    if let button = statusItem.button {
      button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Better Switch")
      button.image?.isTemplate = true
      button.toolTip = "Better Switch"
    }

    let menu = NSMenu()
    menu.delegate = self

    let aboutItem = menu.addItem(
      withTitle: "About Better Switch",
      action: #selector(showAbout),
      keyEquivalent: ""
    )
    aboutItem.target = self

    menu.addItem(.separator())

    let checkForUpdatesItem = menu.addItem(
      withTitle: "Check for Updates…",
      action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
      keyEquivalent: ""
    )
    checkForUpdatesItem.target = updaterController

    menu.addItem(.separator())

    enabledItem = menu.addItem(
      withTitle: "Enabled",
      action: #selector(toggleEnabled),
      keyEquivalent: ""
    )
    enabledItem.target = self

    restoreShakeItem = menu.addItem(
      withTitle: "Restore Shaken Windows", action: #selector(restoreShakenWindows), keyEquivalent: ""
    )
    restoreShakeItem.target = self

    launchAtLoginItem = menu.addItem(
      withTitle: "Launch at Login",
      action: #selector(toggleLaunchAtLogin),
      keyEquivalent: ""
    )
    launchAtLoginItem.target = self

    menu.addItem(.separator())

    accessibilityItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
    accessibilityItem.isEnabled = false

    grantAccessibilityItem = menu.addItem(
      withTitle: "Grant Accessibility Permission…",
      action: #selector(requestAccessibilityPermission),
      keyEquivalent: ""
    )
    grantAccessibilityItem.target = self

    menu.addItem(.separator())

    let quitItem = menu.addItem(
      withTitle: "Quit Better Switch",
      action: #selector(quit),
      keyEquivalent: "q"
    )
    quitItem.target = self

    statusItem.menu = menu
    refreshMenu()
  }

  @objc private func showAbout() {
    var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
    if let iconURL = Bundle.main.url(forResource: "Better Switch", withExtension: "svg"),
       let icon = NSImage(contentsOf: iconURL)
    {
      options[.applicationIcon] = icon
    }

    NSApp.orderFrontStandardAboutPanel(options: options)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func refreshMenu() {
    enabledItem.state = isEnabled ? .on : .off
    restoreShakeItem.isEnabled = !hiddenApplications.isEmpty || !minimizedWindows.isEmpty

    switch SMAppService.mainApp.status {
    case .enabled:
      launchAtLoginItem.title = "Launch at Login"
      launchAtLoginItem.state = .on
    case .requiresApproval:
      launchAtLoginItem.title = "Launch at Login (Approval Required)"
      launchAtLoginItem.state = .mixed
    case .notRegistered, .notFound:
      launchAtLoginItem.title = "Launch at Login"
      launchAtLoginItem.state = .off
    @unknown default:
      launchAtLoginItem.title = "Launch at Login"
      launchAtLoginItem.state = .off
    }

    let isTrusted = AXIsProcessTrusted()
    accessibilityItem.title = isTrusted
      ? "Accessibility: Granted"
      : "Accessibility: Not Granted"
    grantAccessibilityItem.isHidden = isTrusted
  }

  @objc private func toggleEnabled() {
    isEnabled.toggle()
    UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
    if !isEnabled {
      pendingActivationCheck?.cancel()
      pendingActivationCheck = nil
      cancelFocusChecks()
      resetShakeDrag()
      restoreShakenWindows()
    }
    refreshMenu()
    logger.info("Enabled changed to \(self.isEnabled, privacy: .public)")
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem === restoreShakeItem {
      return !hiddenApplications.isEmpty || !minimizedWindows.isEmpty
    }
    return true
  }

  @objc private func restoreShakenWindows() {
    cancelFocusChecks()
    pendingFocusConfirmation?.cancel()
    pendingFocusConfirmation = nil
    windowAwaitingConfirmation = nil
    windowRestorer.restoreShakenWindows(
      hiddenApplications: hiddenApplications, minimizedWindows: minimizedWindows
    )
    hiddenApplications.removeAll()
    minimizedWindows.removeAll()
    if restoreShakeItem != nil {
      refreshMenu()
    }
  }

  private func observeMouseDragging() {
    mouseMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
    ) { [weak self] event in
      self?.handleShakeDrag(event)
    }
  }

  private func resetShakeDrag() {
    draggedWindow = nil
    shakeSamples.removeAll()
  }

  private func cancelFocusChecks() {
    pendingFocusChecks.forEach { $0.cancel() }
    pendingFocusChecks.removeAll()
  }

  private func keepRestoredWindowInFront(_ window: AXUIElement) {
    cancelFocusChecks()
    windowRestorer.raiseWindow(window)
    var pid: pid_t = 0
    guard AXUIElementGetPid(window, &pid) == .success else { return }
    // Other windows can finish their restore animation after the AX call returns.
    for delay in [0.2, 0.5, 1.0] {
      let check = DispatchWorkItem { [weak self] in
        guard let self, self.isEnabled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        else { return }
        self.windowRestorer.raiseWindow(window)
      }
      pendingFocusChecks.append(check)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: check)
    }
  }

  private func scheduleFocusConfirmation() {
    guard let window = windowAwaitingConfirmation else { return }
    pendingFocusConfirmation?.cancel()
    let check = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.pendingFocusConfirmation = nil
      // Confirm after the animation delay even if the same title-bar drag continues.
      self.windowAwaitingConfirmation = nil
      let newlyHidden = self.windowRestorer.confirmWindowFocus(
        keeping: window, minimizedWindows: self.minimizedWindows,
        hiddenApplications: self.hiddenApplications
      )
      self.hiddenApplications.append(contentsOf: newlyHidden)
      if !newlyHidden.isEmpty {
        // A deferred hide is part of the same action; start its cooldown after it finishes.
        self.shakeSamples.removeAll()
        self.shakeReadyAt = ProcessInfo.processInfo.systemUptime + Self.shakeCooldown
      }
      self.refreshMenu()
    }
    pendingFocusConfirmation = check
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: check)
  }

  private func handleShakeDrag(_ event: NSEvent) {
    if event.type == .leftMouseDown {
      cancelFocusChecks()
      pendingFocusConfirmation?.cancel()
      pendingFocusConfirmation = nil
      windowAwaitingConfirmation = nil
    } else if event.type == .leftMouseUp {
      scheduleFocusConfirmation()
    }
    guard isEnabled, AXIsProcessTrusted(), event.type != .leftMouseUp else {
      resetShakeDrag()
      return
    }

    if event.type == .leftMouseDown {
      resetShakeDrag()
      // CGEvent and Accessibility both use a top-left origin, including on other displays.
      guard let point = event.cgEvent?.location,
            let window = windowRestorer.window(at: point),
            let bounds = windowRestorer.bounds(of: window)
      else { return }
      draggedWindow = window
      draggedWindowSize = bounds.size
      if event.timestamp >= shakeReadyAt {
        shakeSamples = [(event.timestamp, bounds.minX)]
      }
      return
    }

    // Ignore queued drag events and animation-related focus changes during the cooldown.
    guard event.timestamp >= shakeReadyAt else { return }
    // AX queries cross process boundaries; sample at most about 30 times per second.
    if let last = shakeSamples.last, event.timestamp - last.time < 0.03 { return }
    guard let window = draggedWindow,
          let bounds = windowRestorer.bounds(of: window),
          abs(bounds.width - draggedWindowSize.width) < 1,
          abs(bounds.height - draggedWindowSize.height) < 1,
          windowRestorer.isFrontmostWindow(window)
    else {
      resetShakeDrag()
      return
    }

    // Measure the window itself: dragging content or resizing must not trigger a shake.
    shakeSamples.append((event.timestamp, bounds.minX))
    shakeSamples.removeAll { event.timestamp - $0.time > 1 }
    guard WindowRestorer.isShake(shakeSamples, notBefore: shakeReadyAt) else { return }

    // Keep tracking the held window, but require a fresh shake for the next action.
    shakeSamples.removeAll()
    pendingActivationCheck?.cancel()
    if !hiddenApplications.isEmpty || !minimizedWindows.isEmpty {
      restoreShakenWindows()
      keepRestoredWindowInFront(window)
    } else {
      let result = windowRestorer.focusWindow(window)
      hiddenApplications = result.hiddenApplications
      minimizedWindows = result.minimizedWindows
      windowAwaitingConfirmation = window
      scheduleFocusConfirmation()
      refreshMenu()
    }
    // Start the cooldown when synchronous window operations finish, not at gesture detection.
    shakeReadyAt = ProcessInfo.processInfo.systemUptime + Self.shakeCooldown
  }

  @objc private func toggleLaunchAtLogin() {
    let service = SMAppService.mainApp

    do {
      switch service.status {
      case .enabled:
        try service.unregister()
        logger.info("Launch at login disabled")
      case .requiresApproval:
        SMAppService.openSystemSettingsLoginItems()
        logger.info("Opened Login Items settings for approval")
      case .notRegistered, .notFound:
        try service.register()
        logger.info("Launch at login registration requested")
        if service.status == .requiresApproval {
          SMAppService.openSystemSettingsLoginItems()
        }
      @unknown default:
        logger.error("Cannot change launch at login: unknown service status")
      }
    } catch {
      logger.error(
        "Failed to change launch at login: \(error.localizedDescription, privacy: .public)"
      )
    }

    refreshMenu()
  }

  @objc private func requestAccessibilityPermission() {
    let options: NSDictionary = [
      kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true,
    ]
    let isTrusted = AXIsProcessTrustedWithOptions(options)
    logger.info("Accessibility request returned trusted=\(isTrusted, privacy: .public)")
    refreshMenu()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  private func observeApplicationActivation() {
    workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      self?.applicationDidActivate(notification)
    }
  }

  private func applicationDidActivate(_ notification: Notification) {
    guard isEnabled,
          let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
    else {
      return
    }

    let pid = application.processIdentifier
    guard pid != ProcessInfo.processInfo.processIdentifier else {
      return
    }

    pendingActivationCheck?.cancel()

    let appName = application.localizedName ?? "Unknown"
    let bundleIdentifier = application.bundleIdentifier
    let bundleURL = application.bundleURL
    logger.info(
      "Activation notification: \(appName, privacy: .public) pid=\(pid, privacy: .public) policy=\(application.activationPolicy.rawValue, privacy: .public)"
    )
    guard application.activationPolicy != .prohibited else {
      logger.debug("Skipping \(appName, privacy: .public): prohibited activation policy")
      return
    }

    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.isEnabled else { return }
      guard let currentApplication = NSWorkspace.shared.frontmostApplication else {
        return
      }
      if pid > 0 {
        guard currentApplication.processIdentifier == pid else {
          self.logger.debug("Skipping \(appName, privacy: .public): no longer frontmost")
          return
        }
      } else {
        guard let bundleIdentifier,
              currentApplication.bundleIdentifier == bundleIdentifier,
              bundleURL == nil || currentApplication.bundleURL == bundleURL
        else {
          self.logger.debug("Skipping \(appName, privacy: .public): no matching frontmost application")
          return
        }
      }
      guard AXIsProcessTrusted() else {
        self.logger.debug("Skipping \(appName, privacy: .public): Accessibility not granted")
        return
      }
      guard currentApplication.activationPolicy != .prohibited else {
        return
      }

      let currentAppName = currentApplication.localizedName ?? appName
      self.logger.info(
        "Activated: \(currentAppName, privacy: .public) pid=\(currentApplication.processIdentifier, privacy: .public) finishedLaunching=\(currentApplication.isFinishedLaunching, privacy: .public)"
      )
      self.windowRestorer.restoreWindowIfNeeded(for: currentApplication)
    }

    pendingActivationCheck = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: workItem)
  }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
