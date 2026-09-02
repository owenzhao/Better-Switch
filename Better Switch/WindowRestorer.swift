import AppKit
import ApplicationServices
import OSLog

struct WindowRestorer {
  private let logger = Logger(subsystem: "com.parussoft.Better-Switch", category: "WindowRestore")

  func restoreWindowIfNeeded(for application: NSRunningApplication) {
    let pid = application.processIdentifier
    let appName = application.localizedName ?? "Unknown"

    if hasOnscreenWindow(for: pid) {
      logger.info("Visible window found for \(appName, privacy: .public). No action")
      return
    }

    let appElement = AXUIElementCreateApplication(pid)
    guard let windows = copyAttribute(appElement, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
      logger.info("No AX windows for \(appName, privacy: .public). No action")
      return
    }

    guard !windows.isEmpty else {
      reopen(application)
      return
    }

    let candidateWindows = windows.filter(isWindow)
    guard !candidateWindows.isEmpty else {
      logger.info("No AXWindow candidates for \(appName, privacy: .public). No action")
      return
    }

    var minimizedWindows: [AXUIElement] = []
    for window in candidateWindows {
      guard let isMinimized = boolAttribute(window, kAXMinimizedAttribute as CFString) else {
        logger.info("Could not verify every AX window for \(appName, privacy: .public). No action")
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

  private func reopen(_ application: NSRunningApplication) {
    let pid = application.processIdentifier
    let appName = application.localizedName ?? "Unknown"

    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
      logger.info("Skipping reopen for \(appName, privacy: .public): no longer frontmost")
      return
    }
    guard let bundleURL = application.bundleURL else {
      logger.error("Cannot reopen \(appName, privacy: .public): bundle URL unavailable")
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
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
}
