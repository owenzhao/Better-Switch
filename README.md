# Better Switch

Better Switch is a macOS menu bar utility that brings back a minimized or closed window when you switch to an app with `⌘Tab` or `⌘\``.

When the activated app has no visible window, Better Switch restores and raises one of its minimized standard windows. If the app has no windows at all, it requests that macOS reopen the app. It leaves apps alone when a usable window is already visible or their window state cannot be safely determined.

## Demo

[Watch the demo video (MP4, 4.1 MB)](https://github.com/owenzhao/Better-Switch/releases/download/v0.1.0/Better-Switch-0.1.0-demo.mp4)

## Requirements

- macOS 15 or later
- Accessibility permission

## Use

1. Build and run the `Better Switch` target in Xcode.
2. Grant Accessibility permission when prompted. You can also use **Grant Accessibility Permission…** from the menu bar icon.
3. Switch to an app with no visible windows. Better Switch restores a minimized window, or reopens the app when it has no windows.

The menu bar item also lets you temporarily disable the behavior and enable launch at login.

## Build

Open `Better Switch.xcodeproj` in Xcode and run the **Better Switch** scheme.

## License

This project is available under the [MIT License](LICENSE).
