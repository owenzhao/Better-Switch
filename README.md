# Better Switch

Better Switch is a macOS menu bar utility that brings back a minimized window when you switch to an app with `⌘Tab` or `⌘\``.

When the activated app has no visible window and all of its standard windows are minimized, Better Switch restores and raises one window. It leaves apps alone when a usable window is already visible or their window state cannot be safely determined.

## Requirements

- macOS 15 or later
- Accessibility permission

## Use

1. Build and run the `Better Switch` target in Xcode.
2. Grant Accessibility permission when prompted. You can also use **Grant Accessibility Permission…** from the menu bar icon.
3. Switch to an app whose windows are all minimized. Better Switch restores one of them.

The menu bar item also lets you temporarily disable the behavior and enable launch at login.

## Build

Open `Better Switch.xcodeproj` in Xcode and run the **Better Switch** scheme.

## License

This project is available under the [MIT License](LICENSE).
