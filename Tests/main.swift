import AppKit

// Run with: xcrun swiftc "Better Switch/WindowRestorer.swift" Tests/main.swift -o /tmp/better-switch-shake-tests && /tmp/better-switch-shake-tests
func check(
  _ name: String, _ positions: [CGFloat], interval: TimeInterval = 0.1, expected: Bool
) {
  let samples = positions.enumerated().map { (time: Double($0.offset) * interval, x: $0.element) }
  precondition(WindowRestorer.isShake(samples) == expected, name)
  print("PASS: \(name)")
}

check("empty drag", [], expected: false)
check("stationary window", [100, 100, 100, 100, 100], expected: false)
check("normal one-way drag", [0, 40, 80, 120, 160, 200], expected: false)
check("small pointer/window jitter", [0, 10, -10, 10, -10, 10], expected: false)
check("jitter during a long drag", [0, 50, 45, 90, 85, 130, 125, 170], expected: false)
check("one reversal", [0, 60, 0], expected: false)
check("two reversals", [0, 60, 0, 60], expected: false)
check("three reversals", [0, 60, 0, 60, 0], expected: true)
check("starts leftward", [0, -60, 0, -60, 0], expected: true)
check("minimum stroke amplitude", [0, 30, 0, 30, 0], expected: true)
check("below stroke amplitude", [0, 29, 0, 29, 0], expected: false)
check("slow back and forth", [0, 60, 0, 60, 0], interval: 0.4, expected: false)
check("exact one-second boundary", [0, 60, 0, 60, 0], interval: 0.25, expected: true)
check("outside one-second boundary", [0, 60, 0, 60, 0], interval: 0.251, expected: false)
check("shake after a long normal drag", [0, 60, 120, 180, 240, 300, 240, 300, 240], interval: 0.2, expected: true)
check("negative display coordinates", [-500, -440, -500, -440, -500], expected: true)
check("gradual direction changes", [0, 15, 30, 60, 45, 30, 0, 15, 30, 60, 45, 30, 0], interval: 0.05, expected: true)

// WindowServer snapshots must include covered windows, multiple apps and other displays,
// without requiring window titles (which can be unavailable without screen recording permission).
func windowInfo(pid: pid_t, frame: CGRect, layer: Int = 0, alpha: Double = 1, onscreen: Bool = true) -> [String: Any] {
  [
    kCGWindowOwnerPID as String: NSNumber(value: pid),
    kCGWindowLayer as String: NSNumber(value: layer),
    kCGWindowAlpha as String: NSNumber(value: alpha),
    kCGWindowIsOnscreen as String: NSNumber(value: onscreen),
    kCGWindowBounds as String: frame.dictionaryRepresentation,
  ]
}

let mainFrame = CGRect(x: 100, y: 100, width: 900, height: 600)
let otherDisplayFrame = CGRect(x: -1400, y: -400, width: 900, height: 600)
let desktopWindows = WindowRestorer.visibleWindowBounds([
  windowInfo(pid: 101, frame: mainFrame),
  windowInfo(pid: 102, frame: mainFrame), // Another app can have an identical, covered window.
  windowInfo(pid: 102, frame: otherDisplayFrame),
  windowInfo(pid: 103, frame: mainFrame, layer: 25),
  windowInfo(pid: 104, frame: mainFrame, alpha: 0),
  windowInfo(pid: 105, frame: mainFrame, onscreen: false),
  windowInfo(pid: 106, frame: .zero),
  [kCGWindowOwnerPID as String: NSNumber(value: 107)],
])
precondition(desktopWindows[101] == [mainFrame], "visible windows without titles")
print("PASS: visible windows without titles")
precondition(desktopWindows[102] == [mainFrame, otherDisplayFrame], "covered windows and other displays")
print("PASS: covered windows and other displays")
precondition(desktopWindows[103] == nil, "menu bar and overlays excluded")
print("PASS: menu bar and overlays excluded")
precondition(desktopWindows[104] == nil && desktopWindows[105] == nil, "invisible and off-desktop windows excluded")
print("PASS: invisible and off-desktop windows excluded")
precondition(desktopWindows[106] == nil && desktopWindows[107] == nil, "empty and incomplete metadata excluded")
print("PASS: empty and incomplete metadata excluded")

func checkCooldown(
  _ name: String, samples: [(time: TimeInterval, x: CGFloat)], readyAt: TimeInterval, expected: Bool
) {
  precondition(WindowRestorer.isShake(samples, notBefore: readyAt) == expected, name)
  print("PASS: \(name)")
}

let firstShake: [(time: TimeInterval, x: CGFloat)] = [
  (0, 0), (0.1, 60), (0.2, 0), (0.3, 60), (0.4, 0),
]
let nextShake: [(time: TimeInterval, x: CGFloat)] = [
  (1.2, 0), (1.3, 60), (1.4, 0), (1.5, 60), (1.6, 0),
]
checkCooldown("movement during cooldown ignored", samples: firstShake, readyAt: 1.2, expected: false)
checkCooldown("fresh shake at cooldown boundary", samples: nextShake, readyAt: 1.2, expected: true)
checkCooldown("old movements cannot complete a new shake", samples: [
  (1.0, 0), (1.1, 60), (1.2, 0), (1.3, 60), (1.4, 0),
], readyAt: 1.2, expected: false)
checkCooldown("sample just before cooldown boundary excluded", samples: [
  (1.199, 0), (1.2, 60), (1.3, 0), (1.4, 60), (1.5, 0),
], readyAt: 1.2, expected: false)
checkCooldown("continuous stream detects next shake", samples: firstShake + nextShake, readyAt: 1.2, expected: true)
checkCooldown("next action also has a cooldown", samples: nextShake, readyAt: 2.8, expected: false)
