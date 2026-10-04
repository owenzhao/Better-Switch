import AppKit
import ApplicationServices
import OSLog

struct WindowRestorer {
  private let logger = Logger(subsystem: "com.parussoft.Better-Switch", category: "WindowRestore")

  static func isShake(
    _ samples: [(time: TimeInterval, x: CGFloat)], notBefore readyAt: TimeInterval = 0
  ) -> Bool {
    guard let latest = samples.last else { return false }
    let positions = samples.filter { $0.time >= readyAt && latest.time - $0.time <= 1 }.map(\.x)
    guard let first = positions.first else { return false }
    var extreme = first
    var direction = 0
    var reversals = 0

    for x in positions.dropFirst() {
      let delta = x - extreme
      if direction == 0 {
        guard abs(delta) >= 30 else { continue }
        direction = delta > 0 ? 1 : -1
        extreme = x
      } else if delta * CGFloat(direction) > 0 {
        extreme = x
      } else if abs(delta) >= 30 {
        direction = -direction
        extreme = x
        reversals += 1
        if reversals >= 3 { return true }
      }
    }
    return false
  }

  func window(at point: CGPoint) -> AXUIElement? {
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(
      AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit
    ) == .success, let hit else { return nil }

    AXUIElementSetMessagingTimeout(hit, 0.2)
    let window = isWindow(hit) ? hit : elementAttribute(hit, kAXWindowAttribute as CFString)
    guard let window, isStandardWindow(window) else { return nil }
    AXUIElementSetMessagingTimeout(window, 0.2)
    return window
  }

  func bounds(of window: AXUIElement) -> CGRect? {
    guard let position = copyAttribute(window, kAXPositionAttribute as CFString),
          CFGetTypeID(position) == AXValueGetTypeID(),
          let size = copyAttribute(window, kAXSizeAttribute as CFString),
          CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions)
    else { return nil }
    return CGRect(origin: point, size: dimensions)
  }

  func isFrontmostWindow(_ window: AXUIElement) -> Bool {
    var pid: pid_t = 0
    guard AXUIElementGetPid(window, &pid) == .success,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          let focused = elementAttribute(
            AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString
          )
    else { return false }
    return CFEqual(window, focused)
  }

  func focusWindow(
    _ selectedWindow: AXUIElement
  ) -> (hiddenApplications: [NSRunningApplication], minimizedWindows: [AXUIElement]) {
    var hiddenApplications: [NSRunningApplication] = []
    var minimizedWindows: [AXUIElement] = []
    var selectedPID: pid_t = 0
    guard AXUIElementGetPid(selectedWindow, &selectedPID) == .success,
          isFrontmostWindow(selectedWindow), isStandardWindow(selectedWindow),
          let visibleInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
          ) as? [[String: Any]]
    else { return (hiddenApplications, minimizedWindows) }

    // Match AX frames against public WindowServer metadata. No window titles or screen capture needed.
    let visibleBounds = Self.visibleWindowBounds(visibleInfo)

    for application in NSWorkspace.shared.runningApplications {
      let pid = application.processIdentifier
      guard pid != ProcessInfo.processInfo.processIdentifier,
            application.activationPolicy != .prohibited, !application.isHidden,
            let frames = visibleBounds[pid]
      else { continue }
      let appElement = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(appElement, 0.5)
      guard let windows = copyAttribute(appElement, kAXWindowsAttribute as CFString) as? [AXUIElement],
            !windows.isEmpty
      else {
        if pid != selectedPID,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == selectedPID,
           setHidden(true, for: application) {
          hiddenApplications.append(application)
        }
        continue
      }

      let windowFrames = windows.compactMap { window -> (window: AXUIElement, frame: CGRect)? in
        // On-screen metadata decides visibility. AXMinimized can lag behind a restore.
        guard isStandardWindow(window), let frame = bounds(of: window) else { return nil }
        return (window, frame)
      }
      let candidates = windowFrames.filter { candidate in
        guard !CFEqual(candidate.window, selectedWindow) else { return false }
        let visibleCount = frames.filter { Self.framesMatch($0, candidate.frame) }.count
        guard visibleCount > 0 else { return false }
        return windowFrames.filter { Self.framesMatch($0.frame, candidate.frame) }.count <= visibleCount
      }
      logger.info("Shake candidates: pid=\(pid, privacy: .public) visible=\(frames.count, privacy: .public) AX=\(windows.count, privacy: .public) matched=\(candidates.count, privacy: .public)")
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == selectedPID else { break }

      // If visible windows cannot be matched safely, use the app-level fallback.
      var needsHide = candidates.isEmpty
      for candidate in candidates {
        let window = candidate.window
        if let button = elementAttribute(window, kAXMinimizeButtonAttribute as CFString),
           boolAttribute(button, kAXEnabledAttribute as CFString) == false {
          needsHide = true
          continue
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
          window, kAXMinimizedAttribute as CFString, &settable
        ) == .success, settable.boolValue else {
          needsHide = true
          continue
        }
        let result = AXUIElementSetAttributeValue(
          window, kAXMinimizedAttribute as CFString, kCFBooleanTrue
        )
        if result == .success {
          // Success acknowledges the request; animations and AX state updates are asynchronous.
          minimizedWindows.append(window)
        } else {
          needsHide = true
          logger.info("Minimize request failed: pid=\(pid, privacy: .public) AX=\(result.rawValue, privacy: .public)")
        }
      }
      if needsHide && pid != selectedPID,
         NSWorkspace.shared.frontmostApplication?.processIdentifier == selectedPID,
         setHidden(true, for: application) {
        hiddenApplications.append(application)
      }
    }
    logger.info("Shake focus requested: hidden apps=\(hiddenApplications.count, privacy: .public), minimized windows=\(minimizedWindows.count, privacy: .public)")
    return (hiddenApplications, minimizedWindows)
  }

  static func visibleWindowBounds(_ visibleInfo: [[String: Any]]) -> [pid_t: [CGRect]] {
    var visibleBounds: [pid_t: [CGRect]] = [:]
    for info in visibleInfo {
      guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != false,
            (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
            let dictionary = info[kCGWindowBounds as String] as? NSDictionary
      else { continue }
      var frame = CGRect.zero
      guard CGRectMakeWithDictionaryRepresentation(dictionary, &frame),
            frame.width > 0, frame.height > 0
      else { continue }
      visibleBounds[pid, default: []].append(frame)
    }

    return visibleBounds
  }

  func confirmWindowFocus(
    keeping selectedWindow: AXUIElement, minimizedWindows: [AXUIElement],
    hiddenApplications: [NSRunningApplication]
  ) -> [NSRunningApplication] {
    var selectedPID: pid_t = 0
    guard AXUIElementGetPid(selectedWindow, &selectedPID) == .success,
          isFrontmostWindow(selectedWindow),
          let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
          ) as? [[String: Any]]
    else { return [] }
    let visibleBounds = Self.visibleWindowBounds(info)
    let alreadyHiddenPIDs = Set(hiddenApplications.map(\.processIdentifier))
    var pids = alreadyHiddenPIDs
    for window in minimizedWindows {
      var pid: pid_t = 0
      if AXUIElementGetPid(window, &pid) == .success { pids.insert(pid) }
    }
    var newlyHidden: [NSRunningApplication] = []
    for pid in pids {
      guard pid != selectedPID, visibleBounds[pid] != nil,
            let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated
      else { continue }
      // A successful AX request can still leave a non-miniaturizable window on screen.
      logger.info("Windows remain after minimize: pid=\(pid, privacy: .public); hiding app")
      if setHidden(true, for: application), !alreadyHiddenPIDs.contains(pid) {
        newlyHidden.append(application)
      }
    }
    return newlyHidden
  }

  private func setHidden(_ hidden: Bool, for application: NSRunningApplication) -> Bool {
    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    AXUIElementSetMessagingTimeout(appElement, 0.5)
    let result = AXUIElementSetAttributeValue(
      appElement, kAXHiddenAttribute as CFString, hidden ? kCFBooleanTrue : kCFBooleanFalse
    )
    if result == .success { return true }
    let sent = hidden ? application.hide() : application.unhide()
    if !sent {
      logger.error("Could not change app visibility: pid=\(application.processIdentifier, privacy: .public) hidden=\(hidden, privacy: .public) AX=\(result.rawValue, privacy: .public)")
    }
    return sent
  }

  private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2
      && abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
  }

  func raiseWindow(_ window: AXUIElement) {
    var pid: pid_t = 0
    guard AXUIElementGetPid(window, &pid) == .success, isWindow(window),
          boolAttribute(window, kAXMinimizedAttribute as CFString) != true,
          let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated
    else { return }
    let appElement = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
    application.activate(options: [])
    let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    if result != .success {
      logger.error("Could not raise shaken window: AX error \(result.rawValue, privacy: .public)")
    }
  }

  func restoreShakenWindows(
    hiddenApplications: [NSRunningApplication], minimizedWindows: [AXUIElement]
  ) {
    for application in hiddenApplications where !application.isTerminated {
      _ = setHidden(false, for: application)
    }
    for window in minimizedWindows {
      let result = AXUIElementSetAttributeValue(
        window, kAXMinimizedAttribute as CFString, kCFBooleanFalse
      )
      if result != .success {
        logger.error("Could not restore shaken window: AX error \(result.rawValue, privacy: .public)")
      }
    }
  }

  private func isStandardWindow(_ window: AXUIElement) -> Bool {
    isWindow(window)
      && stringAttribute(window, kAXSubroleAttribute as CFString) == kAXStandardWindowSubrole as String
      && boolAttribute(window, "AXFullScreen" as CFString) != true
  }

  func restoreWindowIfNeeded(for application: NSRunningApplication) {
    let pid = application.processIdentifier
    let appName = application.localizedName ?? "Unknown"

    if hasOnscreenWindow(for: pid) {
      logger.info("Visible window found for \(appName, privacy: .public). No action")
      return
    }

    let appElement = AXUIElementCreateApplication(pid)
    guard let windows = copyAttribute(appElement, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
      restoreFromWindowMenuOrReopen(application, appElement: appElement, canReopen: false)
      return
    }

    guard !windows.isEmpty else {
      restoreFromWindowMenuOrReopen(application, appElement: appElement)
      return
    }

    let candidateWindows = windows.filter(isWindow)
    guard !candidateWindows.isEmpty else {
      restoreFromWindowMenuOrReopen(application, appElement: appElement, canReopen: false)
      return
    }

    var minimizedWindows: [AXUIElement] = []
    for window in candidateWindows {
      guard let isMinimized = boolAttribute(window, kAXMinimizedAttribute as CFString) else {
        restoreFromWindowMenuOrReopen(application, appElement: appElement, canReopen: false)
        return
      }
      guard isMinimized else {
        logger.info("A non-minimized AX window exists for \(appName, privacy: .public). No action")
        return
      }
      minimizedWindows.append(window)
    }

    guard let window = preferredWindow(
      in: minimizedWindows,
      appElement: appElement
    ) else {
      logger.info("No minimized window selected for \(appName, privacy: .public). No action")
      return
    }

    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
      logger.info("Skipping restore for \(appName, privacy: .public): no longer frontmost")
      return
    }

    let title = (copyAttribute(window, kAXTitleAttribute as CFString) as? String) ?? "Untitled"
    let setResult = AXUIElementSetAttributeValue(
      window,
      kAXMinimizedAttribute as CFString,
      kCFBooleanFalse
    )
    guard setResult == .success else {
      logger.error(
        "Failed to unminimize \(title, privacy: .public) for \(appName, privacy: .public): AX error \(setResult.rawValue, privacy: .public)"
      )
      return
    }

    let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    if raiseResult == .success {
      logger.info(
        "Restored one of \(minimizedWindows.count, privacy: .public) minimized windows for \(appName, privacy: .public): \(title, privacy: .public)"
      )
    } else {
      logger.error(
        "Unminimized but failed to raise \(title, privacy: .public) for \(appName, privacy: .public): AX error \(raiseResult.rawValue, privacy: .public)"
      )
    }
  }

  private func restoreFromWindowMenuOrReopen(
    _ application: NSRunningApplication,
    appElement: AXUIElement,
    canReopen: Bool = true
  ) {
    if restoreFromWindowMenu(appElement, appName: application.localizedName ?? "Unknown") {
      return
    }
    // Only a successfully read, empty AX window list justifies creating a window.
    guard canReopen else {
      logger.info("Skipping reopen for \(application.localizedName ?? "Unknown", privacy: .public): AX window state is uncertain")
      return
    }
    reopen(application)
  }

  private func restoreFromWindowMenu(_ appElement: AXUIElement, appName: String) -> Bool {
    guard let menuBar = elementAttribute(appElement, kAXMenuBarAttribute as CFString),
          let menuBarItems = copyAttribute(menuBar, kAXChildrenAttribute as CFString) as? [AXUIElement],
          let windowMenu = menuBarItems.first(where: {
            stringAttribute($0, kAXTitleAttribute as CFString) == "Window"
          }),
          let menu = (copyAttribute(windowMenu, kAXChildrenAttribute as CFString) as? [AXUIElement])?
            .first(where: { stringAttribute($0, kAXRoleAttribute as CFString) == kAXMenuRole as String }),
          let menuItems = copyAttribute(menu, kAXChildrenAttribute as CFString) as? [AXUIElement],
          let separatorIndex = menuItems.lastIndex(where: {
            stringAttribute($0, kAXRoleAttribute as CFString) == "AXSeparator"
          })
    else {
      logger.info("No selectable Window menu item for \(appName, privacy: .public)")
      return false
    }

    for menuItem in menuItems[menuItems.index(after: separatorIndex)...] {
      let title = stringAttribute(menuItem, kAXTitleAttribute as CFString) ?? ""
      let commandCharacter = stringAttribute(menuItem, kAXMenuItemCmdCharAttribute as CFString) ?? ""
      guard !title.isEmpty,
            commandCharacter.isEmpty,
            boolAttribute(menuItem, kAXEnabledAttribute as CFString) == true
      else {
        continue
      }

      let result = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
      if result == .success {
        logger.info("Restored \(title, privacy: .public) for \(appName, privacy: .public) from the Window menu")
        return true
      }
      logger.error("Failed to select \(title, privacy: .public) from the Window menu for \(appName, privacy: .public): AX error \(result.rawValue, privacy: .public)")
    }

    return false
  }

  private func reopen(_ application: NSRunningApplication) {
    let pid = application.processIdentifier
    let appName = application.localizedName ?? "Unknown"

    guard application.isFinishedLaunching else {
      logger.info("Skipping reopen for \(appName, privacy: .public): application is still launching")
      return
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
      logger.info("Skipping reopen for \(appName, privacy: .public): no longer frontmost")
      return
    }
    // A window may have appeared while the AX window/menu queries were in progress.
    guard !hasOnscreenWindow(for: pid) else {
      logger.info("Skipping reopen for \(appName, privacy: .public): a window appeared")
      return
    }
    guard let bundleURL = application.bundleURL else {
      logger.error("Cannot reopen \(appName, privacy: .public): bundle URL unavailable")
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.createsNewApplicationInstance = false
    configuration.addsToRecentItems = false

    NSWorkspace.shared.openApplication(
      at: bundleURL,
      configuration: configuration
    ) { _, error in
      if let error {
        logger.error(
          "Failed to request reopen for \(appName, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      } else {
        logger.info("Requested reopen for \(appName, privacy: .public): AX window list was empty")
      }
    }
  }

  private func hasOnscreenWindow(for pid: pid_t) -> Bool {
    guard let windowInfo = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] else {
      logger.error("CGWindowListCopyWindowInfo failed for pid=\(pid, privacy: .public)")
      return false
    }

    let hasVisibleWindow = windowInfo.contains { info in
      guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
            (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
            (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
            let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary
      else {
        return false
      }

      var bounds = CGRect.zero
      guard CGRectMakeWithDictionaryRepresentation(boundsDictionary, &bounds) else {
        return false
      }
      return bounds.width > 0 && bounds.height > 0
    }

    logger.debug("Visible windows for pid=\(pid, privacy: .public): \(hasVisibleWindow ? 1 : 0, privacy: .public)")
    return hasVisibleWindow
  }

  private func isWindow(_ window: AXUIElement) -> Bool {
    guard let role = copyAttribute(window, kAXRoleAttribute as CFString) as? String,
          role == kAXWindowRole as String
    else {
      return false
    }
    return true
  }

  private func preferredWindow(
    in minimizedWindows: [AXUIElement],
    appElement: AXUIElement
  ) -> AXUIElement? {
    if let focused = windowAttribute(appElement, kAXFocusedWindowAttribute as CFString),
       minimizedWindows.contains(where: { CFEqual($0, focused) }) {
      return focused
    }

    if let main = windowAttribute(appElement, kAXMainWindowAttribute as CFString),
       minimizedWindows.contains(where: { CFEqual($0, main) }) {
      return main
    }

    return minimizedWindows.first
  }

  private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    (copyAttribute(element, attribute) as? NSNumber)?.boolValue
  }

  private func windowAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
    elementAttribute(element, attribute)
  }

  private func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
    guard let value = copyAttribute(element, attribute),
          CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return unsafeBitCast(value, to: AXUIElement.self)
  }

  private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success else {
      logger.debug(
        "AX read failed for \(attribute as String, privacy: .public): \(result.rawValue, privacy: .public)"
      )
      return nil
    }
    return value
  }

  private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    copyAttribute(element, attribute) as? String
  }
}
