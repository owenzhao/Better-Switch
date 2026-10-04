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

## Shake to Focus

Hold a window's title bar and quickly shake it left and right to minimize the other ordinary windows of all apps on the current desktop, across connected displays. The window must actually move, with at least three direction changes of 30 points or more within one second; moving the pointer inside a window or resizing it does not trigger the feature.

Better Switch first tries to minimize each other window. If a window cannot be minimized, it hides that window's app instead. After an animation delay, it checks for other apps' windows still on screen and hides those apps if needed, even while the mouse remains held. The shaken window's own app is never hidden: any of its other windows that cannot be minimized are left visible. No gesture settings are needed. macOS hides entire apps, so the fallback can also hide that app's windows on other desktops.

Shake again or choose **Restore Shaken Windows** from the menu bar to restore only the applications and windows changed by the last shake. After a second shake, Better Switch brings the shaken window forward and rechecks it while the other windows finish restoring. Disabling Better Switch or quitting also restores the changed windows. Previously hidden apps and minimized windows are left alone. Full-screen windows and special panels are skipped.

You can keep holding the title bar throughout: after each action there is a 1.2-second cooldown, then a fresh shake can trigger the next action. Movement during the cooldown is ignored, so one shake does not immediately undo itself.

If visible windows cannot be matched safely to their Accessibility objects, Better Switch uses the hide fallback for other apps. Ambiguous windows belonging to the shaken window's own app are left alone.

## What's New in 0.3.0

- Shake a window's title bar to minimize other apps' windows, with automatic app hiding when minimization is unavailable.
- Shake again to restore the changed windows and bring the shaken window forward.
- Keep holding the title bar between actions; a 1.2-second cooldown prevents immediate toggling.
- Restore the changed windows from the menu bar with **Restore Shaken Windows**.

## What's New in 0.2.2

- Fixes extra Brave Browser windows appearing during a cold launch while Better Switch is running.
- Requests reopening only when the app has finished launching and its window list is confirmed empty.
- Preserves existing minimized-window and Window-menu restoration.

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
