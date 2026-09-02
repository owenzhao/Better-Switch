import AppKit
import ApplicationServices
import OSLog
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private static let enabledKey = "betterSwitchEnabled"

  private let logger = Logger(subsystem: "com.parussoft.Better-Switch", category: "App")
  private let windowRestorer = WindowRestorer()

  private var statusItem: NSStatusItem!
  private var enabledItem: NSMenuItem!
  private var launchAtLoginItem: NSMenuItem!
  private var accessibilityItem: NSMenuItem!
  private var grantAccessibilityItem: NSMenuItem!
  private var workspaceObserver: NSObjectProtocol?
  private var pendingActivationCheck: DispatchWorkItem?
  private var isEnabled = true

  func applicationDidFinishLaunching(_ notification: Notification) {
    UserDefaults.standard.register(defaults: [Self.enabledKey: true])
    isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)

    configureStatusItem()
    observeApplicationActivation()
    logger.info("Better Switch started. Enabled: \(self.isEnabled, privacy: .public)")

    if !AXIsProcessTrusted() {
      requestAccessibilityPermission()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    pendingActivationCheck?.cancel()
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

    enabledItem = menu.addItem(
      withTitle: "Enabled",
      action: #selector(toggleEnabled),
      keyEquivalent: ""
    )
    enabledItem.target = self

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
    }
    refreshMenu()
    logger.info("Enabled changed to \(self.isEnabled, privacy: .public)")
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
    guard pid != ProcessInfo.processInfo.processIdentifier,
          application.activationPolicy == .regular
    else {
      return
    }

    pendingActivationCheck?.cancel()

    let appName = application.localizedName ?? "Unknown"
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.isEnabled else { return }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        self.logger.debug("Skipping \(appName, privacy: .public): no longer frontmost")
        return
      }
      guard AXIsProcessTrusted() else {
        self.logger.debug("Skipping \(appName, privacy: .public): Accessibility not granted")
        return
      }
      guard let currentApplication = NSRunningApplication(processIdentifier: pid),
            currentApplication.activationPolicy == .regular
      else {
        return
      }

      self.logger.info("Activated: \(appName, privacy: .public) pid=\(pid, privacy: .public)")
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
