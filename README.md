# TouchBarPill

TouchBarPill is a menu-bar utility for a Mac whose Touch Bar still receives taps but no longer draws. Collapsed, it is a three-zone notch on the edge you choose. A fresh install uses soft accent, size S, and top center; a saved theme, size, or edge is kept until those defaults are reset. Only the center zone expands into the live adaptive Touch Bar. The left wing is a focus control (a timer icon, then pause and stop). The right wing is system volume. Move the pointer away and, after a short delay, it collapses, unless you pin it open. After a short idle it fades. In a fullscreen space — including browser video fullscreen such as YouTube — it tucks away but stays hittable on the edge. Menus follow the system language (English and Spanish). Opening at login stays off until you turn it on. There is no Preferences window; the status menu is the settings surface.

The picture is not a screenshot. Frames come from the same private Touch Bar simulator interface that open-source simulators use, and clicks are posted back into that simulator so the real buttons fire. The physical OLED does not have to work. macOS still renders the bar on the host, which is why Touché can mirror it.

## How this differs from Touché

Touché proves the adaptive bar can be mirrored, including system prompts (Allow / Don’t Allow), app strips, spelling suggestions, and the Control Strip. Its window stays on screen at full Touch Bar size.

TouchBarPill uses that same class of private API, and changes the window:

- Collapsed, it is a notch of three hit zones. Top and bottom read left to right: focus, center, volume. Left and right stack the same three controls top to bottom (wings upright; the long “Touch Bar” title rotates along the bezel). Drag it along the attached edge, or choose Top center, Bottom center, Left mid, or Right mid. **Hover only the center** opens the strip after a short delay. Hovering either wing cancels that expand.
- Focus (manual only): the left wing shows a timer icon when idle. Click it to start. The center then replaces “Touch Bar” with whole minutes (`0m`, `12m`) and updates when the minute changes, not every second. While a session exists the left wing shows pause and stop; pause freezes the minutes and the wing offers resume; stop ends the session. Focus is only on that wing. The status menu does not include Start, Pause, Resume, or Reset Focus. No goal and no done state. No Accessibility / no other-app watching.
- Fullscreen auto-hide: a system fullscreen space, or a frontmost on-screen window whose frame covers about 98% of the chosen display (YouTube / HTML5 fullscreen), or **Invisible** in the Themes submenu. The notch draws at alpha 0; the wide edge pad stays. Hover reveals it. Detection uses presentation options plus window **bounds** only (`CGWindowListCopyWindowInfo`) — not pixels, not another app’s files, not Accessibility.
- Expanded, the strip is 15% larger than the previous three-quarter mirror (scale 0.75 × 1.15), width, height, padding, and fallback type kept in proportion. It follows the chosen edge (top/bottom centered, or near the left/right bezel) and stays clamped on screen.
- The pointer leaving the strip collapses it after 0.4 seconds. If the leave event is missed (menu bar, another app), a pointer check still collapses once the cursor is outside the notch and the strip. Pin expanded keeps it open until you unpin it from the status menu or right-click → Unpin on the strip.
- When the tab is collapsed and idle for about 1.2 seconds, discreet mode (always on) fades it to about 52% opacity. Hover or expand restores full opacity.
- There is no Dock icon and no Preferences window. A status item has Show/Hide, Display (when more than one screen is attached), Position, Pin expanded, Theme (Black, Graphite, Soft accent, and Invisible), Size S/M, Open at Login, Copy Diagnostics, and Quit. Focus is not in that menu.

The right wing shows a speaker. Hovering it reveals a volume slider anchored to that wing and does not open the Touch Bar. Scroll on the wing or the slider changes system volume (CoreAudio). With natural scrolling on, two fingers toward the top of the trackpad (away from you) raise volume and the bar fills upward toward 100%; two fingers toward you lower it and the bar empties toward 0%. Click or double-click mutes. At 0% or while muted, the wing and the slider show a crossed-out speaker; otherwise the speaker is the ordinary one and the slider shows the percent. Brightness is not reimplemented. The expanded strip is the adaptive bar itself. If the stream cannot attach, the strip becomes a short message and a Try Again button instead of fake stand-in controls.

## Requirements

- A Mac running macOS 12 or later, with Xcode 14 or later (Xcode 15+ is the comfortable target).
- The private framework `DFRFoundation` at `/System/Library/PrivateFrameworks/DFRFoundation.framework`. Touch Bar Macs have it. Some later systems keep the simulator after the hardware is gone; some may remove the symbols. The app still launches if they are missing.
- Quit Touché before launching TouchBarPill. Two clients of the simulator fight each other.

A dead OLED is not a problem. A missing framework is.

## Build and run

Open `TouchBarPill.xcodeproj` and press Run.

If `xcodebuild` is unavailable (Command Line Tools only), use:

```sh
./build-cli.sh
open build/TouchBarPill.app
```

Policy checks (volume scroll sign and leave-collapse) run with the build. Command Line Tools has no XCTest, so the script compiles a small hermetic runner. Tests only:

```sh
./build-cli.sh test
```

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

1. A notch on the chosen edge of the chosen display. A fresh install is soft accent, size S, top center. Ears meet that edge; the free side is rounded. Collapsed, three zones: timer, Touch Bar, speaker.
2. Moving the pointer onto the center grows the strip about 15% larger than the previous three-quarter bar, proportions kept. The wings do not. The strip follows the same edge and stays clamped on that display.
3. The strip shows the same adaptive Touch Bar the frontmost app would draw: Control Strip, function keys, Allow / Don’t Allow, and so on.
4. Clicking a button in the strip activates that button. Try a Control Strip control, or a button in an app that puts real actions on the Touch Bar.
5. Leaving the strip collapses it after about 0.4 seconds. Moving back onto the center cancels the collapse. Pin expanded skips that collapse until you unpin it (status menu or right-click → Unpin).
6. After the collapsed tab sits idle for about 1.2 seconds, it fades. Hovering or expanding brings it back to full opacity. Discreet mode stays on.
7. Click the status item for Show/Hide, Display, Position, Pin expanded, Theme (including Invisible), Size, Open at Login, Copy Diagnostics, and Quit TouchBarPill. Right-click (or Control-click) the expanded strip for Unpin (when pinned) and Quit. Hide is remembered. The status-item icon is still the capsule with three dots. Focus stays on the left wing.

The notch stays on the display you pick. It does not follow the pointer onto another screen. If that display is unplugged, it moves to the built-in display, or the main display, and returns when the saved display is back. Drag the collapsed notch along its attached edge; it cannot leave the display. Top/bottom placements stay flush with that edge; left/right sit mid-height on the bezel. On a notched MacBook display, top placement still meets the physical top; the expanded strip sits just below the menu bar so the camera notch does not cover the controls.

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

The collapse delay is still a `defaults` key. Open at login is off until the user turns it on from the status menu. The app does not register a login item at launch. The bundle id is `com.touchbarpill.TouchBarPill`. Turning it on uses `SMAppService` (macOS 13+). If macOS needs approval, TouchBarPill explains that and can open System Settings → General → Login Items. Login items require macOS 13 or later.

```sh
# Collapse delay in seconds. Default 0.4. Clamped to 0.15...2.
defaults write com.touchbarpill.TouchBarPill CollapseDelay -float 0.5

# Click coordinates. Default event space is 1004×30 points, unless
# DFRGetScreenSize returns a sane one-row size. If clicks land in the
# wrong column, set the width the simulator actually expects.
defaults write com.touchbarpill.TouchBarPill TouchBarPointWidth -float 1085
defaults write com.touchbarpill.TouchBarPill TouchBarPointHeight -float 30

# How long the collapsed tab stays fully opaque before discreet mode
# fades it. Default 1.2 seconds. Clamped to 0.3...8.
defaults write com.touchbarpill.TouchBarPill DiscreetIdleDelay -float 1.2

# Idle opacity, 0.35...0.75. Default 0.52. There is no Preferences window; this key is the control.
defaults write com.touchbarpill.TouchBarPill DiscreetOpacity -float 0.52

# Discreet mode. On when the key is missing.
defaults write com.touchbarpill.TouchBarPill DiscreetMode -bool YES

# AppKit is y-up, which matches the on-screen simulator. Turn this on
# if a control reacts as if you clicked its vertical opposite.
# Most Touch Bar buttons are full height, so this rarely matters.
defaults write com.touchbarpill.TouchBarPill FlipTouchBarY -bool YES

# Mirror the picture top-to-bottom if the strip is upside down.
defaults write com.touchbarpill.TouchBarPill FlipStreamVertically -bool YES
```

Quit and reopen the app after changing them. Copy Diagnostics shows the delay the app is actually using.

## Known fragility

This is a private API. Apple does not document it and has already moved it once. Sindre Sorhus’s Touch Bar Simulator was discontinued because the old integration stopped working. The gen-3 functions still backed working mirrors on macOS Sonoma (PinchBar reads them there). They are not guaranteed on Sequoia, Tahoe, or whatever is current when you build.

- A macOS update can remove `DFRTouchBarSimulatorCreate` or change its arguments. The app is written to notice a missing symbol and say so, not to guess a replacement.
- Running beside Touché, or beside another simulator, can make `DFRTouchBarSimulatorCreate` return nil or show a blank bar.
- Creating the simulator can briefly disturb the hardware Touch Bar even when the OLED is already dead. That is a property of the system service, not of the pill window.
- Full-screen spaces are best-effort. `canJoinAllSpaces` and `fullScreenAuxiliary` are both set, which is what the system documents for an accessory window, and some full-screen apps still hide auxiliary windows.
- Click alignment assumes a linear map of the strip into a 1004×30 point Touch Bar (or `DFRGetScreenSize` when that value looks like a single row). A 16-inch panel whose point size is different needs the defaults above.
- The picture is the raw stream, scaled to the strip. There is no Metal upscaler.

## What is in this milestone, and what is not

In this version (0.3.0):

- Menu-bar agent, no Dock icon, Show/Hide, Quit, Preferences. The status item stays.
- Notch tab on a chosen display, hover expand, leave-to-collapse with a 0.4 second delay.
- Display submenu and a Preferences popup. The saved display id is kept if that screen is unplugged; the tab falls back to the built-in display, or the main display.
- Horizontal position: drag the collapsed notch, or Left / Center / Right. Stored as an anchor plus an offset, and clamped to the display.
- Expanded strip 15% larger than the previous 0.75 scale, top-centered on the chosen display (not aligned under the notch).
- Pin expanded, in the status menu and in Preferences. While pinned, hover-leave does not collapse.
- Discreet mode, on by default. The collapsed idle tab fades. Preferences can set the opacity.
- Open at login, off by default. The status menu and Preferences can turn it on with `SMAppService` (macOS 13+). Launch does not register it.
- English and Spanish from the system language.
- Live gen-3 display stream, with clicks forwarded through `DFRTouchBarSimulatorPostEventWithMouseActivity`.
- A real message when the stream cannot attach, plus Try Again.

Not in this version:

- A warning when Touché is also running.
- A focus hub, Control Center, notarization, Developer ID signing, Sparkle, or a disk image.
- A slider for the collapse delay. The delay is fixed at 0.4 seconds unless the `defaults` key is set. Preferences only displays the value.
- Custom volume or brightness buttons. Those were left out on purpose so a failed stream is obvious.

## Layout

```
TouchBarPill.xcodeproj          Xcode project and shared scheme
TouchBarPill/main.swift         NSApplication, accessory policy
TouchBarPill/AppDelegate.swift  Status item, diagnostics
TouchBarPill/PillPanelController.swift
                                Panel, hover, frames, notch-tab drawing, drag
TouchBarPill/Placement.swift    Display, anchor, pin, discreet opacity
TouchBarPill/TouchBarStreamView.swift
                                Pointer forwarding into the strip
TouchBarPill/ZonePolicy.swift       Collapsed zones, volume scroll sign, leave-collapse
Tests/policy-tests.swift          Volume sign and leave-collapse checks (`./build-cli.sh test`)
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
