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

## What's New in 0.2.1

- Fixes the Sparkle signing build phase for current Xcode versions.
- Keeps Sparkle's nested components correctly signed without interfering with Xcode's final app signing.

## What's New in 0.2.0

- Restores special windows exposed through an app's **Window** menu before falling back to reopening the app.
- Rechecks the frontmost application after switching, making restoration more reliable for apps with unusual activation behavior.
- Checks for updates automatically and supports signed in-app upgrades through Sparkle.

## Updates

Better Switch uses Sparkle to check the update feed automatically and provides **Check for Updates…** in the menu bar item. The feed is [appcast.xml](appcast.xml); published archives must be signed with the Sparkle Ed25519 key kept in the local keychain.

## Build

Open `Better Switch.xcodeproj` in Xcode and run the **Better Switch** scheme.

## License

This project is available under the [MIT License](LICENSE).
