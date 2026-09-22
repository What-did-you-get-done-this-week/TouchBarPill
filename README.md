# TouchBarPill

TouchBarPill is a menu-bar utility for a Mac whose Touch Bar still receives taps but no longer draws. Collapsed, it is a black tab flush with the top center of the screen. Hover the tab and it expands into the live adaptive Touch Bar. Move the pointer away and, after a short delay, it collapses. Menus follow the system language (English and Spanish). Opening at login is on by default.

The picture is not a screenshot. Frames come from the same private Touch Bar simulator interface that open-source simulators use, and clicks are posted back into that simulator so the real buttons fire. The physical OLED does not have to work. macOS still renders the bar on the host, which is why Touché can mirror it.

This tree was written on a Linux machine. It has not been launched. Build and run it on the Mac.

## How this differs from Touché

Touché proves the adaptive bar can be mirrored, including system prompts (Allow / Don’t Allow), app strips, spelling suggestions, and the Control Strip. Its window stays on screen at full Touch Bar size.

TouchBarPill uses that same class of private API, and changes the window:

- Collapsed, it is a notch-style tab about 132×40 points, centered, with its top edge flush against the screen. The top corners are concave ears; the bottom corners are rounded. The only label is “Touch Bar”.
- Expanded, the strip is 15% larger than the previous three-quarter mirror (scale 0.75 × 1.15), width, height, padding, and fallback type kept in proportion.
- Hover, or a click on the tab, expands it into a wide strip.
- The pointer leaving the strip collapses it after 0.4 seconds.
- There is no Dock icon. A status item has Show/Hide, Preferences, Open at Login, Copy Diagnostics, and Quit. The menu-bar icon stays.

Volume and brightness controls are not reimplemented. The expanded strip is the adaptive bar itself. If the stream cannot attach, the strip becomes a short message and a Try Again button instead of fake stand-in controls.

## Requirements

- A Mac running macOS 12 or later, with Xcode 14 or later (Xcode 15+ is the comfortable target).
- The private framework `DFRFoundation` at `/System/Library/PrivateFrameworks/DFRFoundation.framework`. Touch Bar Macs have it. Some later systems keep the simulator after the hardware is gone; some may remove the symbols. The app still launches if they are missing.
- Quit Touché before launching TouchBarPill. Two clients of the simulator fight each other.

A dead OLED is not a problem. A missing framework is.

## Build and run

Open `TouchBarPill.xcodeproj` and press Run.

Or from the repo root:

```sh
xcodebuild \
  -project TouchBarPill.xcodeproj \
  -scheme TouchBarPill \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build
open build/Build/Products/Debug/TouchBarPill.app
```

The target is set up to ad-hoc sign (`CODE_SIGN_IDENTITY = -`) and does not require an Apple Developer team. If Xcode asks for a team, set Signing Certificate to **Sign to Run Locally** and leave App Sandbox off. If `xcodebuild` stops on a signing error, add `CODE_SIGNING_ALLOWED=NO` to the command, then ad-hoc sign the product as below.

On Apple Silicon, an unsigned binary will not start. If `open` says the app is damaged or the signature is invalid:

```sh
codesign --force --deep --sign - build/Build/Products/Debug/TouchBarPill.app
```

If the app was downloaded in a zip and Gatekeeper quarantines it:

```sh
xattr -dr com.apple.quarantine /path/to/TouchBarPill.app
```

The bundle id is `com.touchbarpill.TouchBarPill`. The process is an agent (`LSUIElement`), so it does not appear in the Dock or the Force Quit window’s normal app list. Use the status item to quit, or:

```sh
killall TouchBarPill
```

## What you should see

1. A black tab at the top center of the screen that has the pointer. Its top edge meets the screen edge, with concave ears at the top corners and rounded bottom corners. Collapsed, it shows only the words Touch Bar.
2. Moving the pointer onto it grows a black strip about 15% larger than the previous three-quarter bar, proportions kept.
3. The strip shows the same adaptive Touch Bar the frontmost app would draw: Control Strip, function keys, Allow / Don’t Allow, and so on.
4. Clicking a button in the strip activates that button. Try a Control Strip control, or a button in an app that puts real actions on the Touch Bar.
5. Leaving the strip collapses it after about 0.4 seconds. Moving back onto it cancels the collapse.
6. Click the status item for Show/Hide, Open at Login, and Quit TouchBarPill. Right-click (or Control-click) the tab for Quit as well. Hide is remembered. The status-item icon is still the capsule with three dots.

While collapsed, the tab follows the screen under the pointer and stays flush with that screen’s top edge. It is not dragged. On a notched display the collapsed tab still meets the top edge; the expanded strip sits just below the menu bar so the notch does not cover the controls.

The panel is non-activating and borderless, joins every Space, and is marked `fullScreenAuxiliary` so it can remain visible over full-screen apps. Its window level is one step above status items, which keeps it under pop-up menus. Clicks must not activate TouchBarPill. If they did, the adaptive bar would switch to this app’s empty Touch Bar.

## If the strip does not mirror

Expand the pill. The card states which step failed. The status item’s **Copy Diagnostics** puts the same report on the clipboard. Console.app, subsystem `com.touchbarpill.TouchBarPill`, has the matching log.

Check the framework and the daemon:

```sh
ls /System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation
nm -gU /System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation | grep DFRTouchBarSimulator
pgrep -lf TouchBarServer
```

You want `DFRTouchBarSimulatorCreate`, `DFRTouchBarSimulatorGetTouchBar`, `DFRTouchBarCreateDisplayStream`, and `DFRTouchBarSimulatorPostEventWithMouseActivity`. `TouchBarServer` should be running on a Touch Bar Mac even when the OLED is black.

| What diagnostics say | What it means |
| --- | --- |
| Framework did not load | This Mac has no `DFRFoundation`. The pill UI still runs. There is nothing to mirror. |
| Symbols missing | The framework is there, but this macOS removed the gen-3 simulator entry points. |
| Simulator returned nil | Quit Touché and any other simulator, then Try Again. |
| Waiting for frames | The stream is attached. Focus an app that uses the Touch Bar, or press fn. |
| Frames are arriving but the strip is black | The blit path failed, or the frame really is empty. The blit failure count is in the diagnostics. |
| Picture is right, clicks are wrong | See the defaults below. |

No Accessibility permission is required. Events go into the simulator, not into other apps through the accessibility API. Screen Recording is not requested up front. If a future macOS treats the private display stream as a capture, System Settings → Privacy & Security → Screen & System Audio Recording is the place to allow TouchBarPill.

## Entitlements

`TouchBarPill/TouchBarPill.entitlements` is intentionally empty.

- The App Sandbox is **off**. Sandbox would block `dlopen` of `DFRFoundation` and the display stream. Do not turn sandbox on in Signing & Capabilities.
- No `com.apple.private.*` entitlement is set. Those keys are rejected unless Apple signs the binary, and they would stop a local build from launching.
- `DFRFoundation` is loaded at runtime with `dlopen` / `dlsym` from `/System/Library/PrivateFrameworks`. It is not linked, because it is not part of the public SDK. If a symbol is missing, the function pointer stays null and the expanded card explains that. The process still runs.
- Hardened Runtime is off so a local ad-hoc signature does not fight the private framework. Notarization can turn it back on later; system frameworks in `/System/Library` are normally allowed under Hardened Runtime.

The legacy calls `DFRSetStatus` and `SLSDFRDisplayStreamCreate` are not used. That older path blanks the Touch Bar on some 16-inch MacBook Pros. TouchBarPill only calls the second-generation simulator (`DFRTouchBarSimulatorCreate(3, nil, 3)`), which is the entry point the later open-source simulators and Touché’s reliable path use.

Nothing here is copied from Touché. The call pattern follows public research: [jslegendre/TouchBar-Simulator](https://github.com/jslegendre/TouchBar-Simulator) (gen-3 simulator, display stream, mouse posting) and [zac/PinchBar](https://github.com/zac/PinchBar) (the same calls in-process on Sonoma). Rendering is a Core Image copy of each `IOSurface` into the pill, not those projects’ Metal shaders or XPC view bridge.

## Knobs

The collapse delay is still a `defaults` key. Open at login is a real switch in Preferences and in the status menu (on by default). The bundle id is `com.touchbarpill.TouchBarPill`. macOS may ask you to allow the login item under System Settings → General → Login Items; an ad-hoc signature often lands in “needs approval” until you allow it there. Login items require macOS 13 or later (`SMAppService`).

```sh
# Collapse delay in seconds. Default 0.4. Clamped to 0.15...2.
defaults write com.touchbarpill.TouchBarPill CollapseDelay -float 0.5

# Click coordinates. Default event space is 1004×30 points, unless
# DFRGetScreenSize returns a sane one-row size. If clicks land in the
# wrong column, set the width the simulator actually expects.
defaults write com.touchbarpill.TouchBarPill TouchBarPointWidth -float 1085
defaults write com.touchbarpill.TouchBarPill TouchBarPointHeight -float 30

# AppKit is y-up, which matches the on-screen simulator. Turn this on
# if a control reacts as if you clicked its vertical opposite.
# Most Touch Bar buttons are full height, so this rarely matters.
defaults write com.touchbarpill.TouchBarPill FlipTouchBarY -bool YES

# Mirror the picture top-to-bottom if the strip is upside down.
defaults write com.touchbarpill.TouchBarPill FlipStreamVertically -bool YES
```

Quit and reopen the app after changing them. Preferences shows the delay it is actually using.

## Known fragility

This is a private API. Apple does not document it and has already moved it once. Sindre Sorhus’s Touch Bar Simulator was discontinued because the old integration stopped working. The gen-3 functions still backed working mirrors on macOS Sonoma (PinchBar reads them there). They are not guaranteed on Sequoia, Tahoe, or whatever is current when you build.

- A macOS update can remove `DFRTouchBarSimulatorCreate` or change its arguments. The app is written to notice a missing symbol and say so, not to guess a replacement.
- Running beside Touché, or beside another simulator, can make `DFRTouchBarSimulatorCreate` return nil or show a blank bar.
- Creating the simulator can briefly disturb the hardware Touch Bar even when the OLED is already dead. That is a property of the system service, not of the pill window.
- Full-screen spaces are best-effort. `canJoinAllSpaces` and `fullScreenAuxiliary` are both set, which is what the system documents for an accessory window, and some full-screen apps still hide auxiliary windows.
- Click alignment assumes a linear map of the strip into a 1004×30 point Touch Bar (or `DFRGetScreenSize` when that value looks like a single row). A 16-inch panel whose point size is different needs the defaults above.
- The picture is the raw stream, scaled to the strip. There is no Metal upscaler.

## What is in this milestone, and what is not

In this version:

- Menu-bar agent, no Dock icon, Show/Hide, Quit, Preferences. The status item stays.
- Top-center notch tab, hover expand, leave-to-collapse with a 0.4 second delay.
- Expanded strip 15% larger than the previous 0.75 scale.
- Open at login, on by default, via `SMAppService` (macOS 13+).
- English and Spanish from the system language.
- Live gen-3 display stream, with clicks forwarded through `DFRTouchBarSimulatorPostEventWithMouseActivity`.
- A real message when the stream cannot attach, plus Try Again.
- The tab follows the screen under the pointer while it is collapsed.

Not in this version:

- A control to pin the tab to one display. It always follows the pointer while collapsed.
- A slider for the collapse delay. The delay is fixed at 0.4 seconds unless the `defaults` key is set. Preferences only displays the value.
- Notarization, Developer ID signing, and Sparkle.
- Custom volume or brightness buttons. Those were left out on purpose so a failed stream is obvious.

## Layout

```
TouchBarPill.xcodeproj          Xcode project and shared scheme
TouchBarPill/main.swift         NSApplication, accessory policy
TouchBarPill/AppDelegate.swift  Status item, diagnostics
TouchBarPill/PillPanelController.swift
                                Panel, hover, frames, notch-tab drawing
TouchBarPill/TouchBarStreamView.swift
                                Pointer forwarding into the strip
TouchBarPill/PreferencesController.swift
TouchBarPill/LaunchAtLogin.swift  SMAppService login item
TouchBarPill/L10n.swift            NSLocalizedString helper
TouchBarPill/en.lproj/Localizable.strings
TouchBarPill/es.lproj/Localizable.strings
TouchBarPill/DFRMirror.h
TouchBarPill/DFRMirror.m        dlopen, simulator, stream, clicks
TouchBarPill/Info.plist         LSUIElement
TouchBarPill/TouchBarPill.entitlements
```

Minimum system version is macOS 12 so a 2016–2017 Touch Bar Mac on Monterey can still open the project. The private calls themselves are older than that.
