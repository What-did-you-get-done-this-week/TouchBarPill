# TouchBarPill

TouchBarPill is a notch for a MacBook whose Touch Bar OLED is dead but still accepts input. macOS still draws that bar. This app mirrors it on the screen edge and sends taps back, so the Control Strip and app buttons keep working even when the glass stays black.

Collapsed, it is a small notch. Hover the center and the live Touch Bar opens. A new install leaves Pin Touch bar off, so the strip closes again when the pointer leaves. The status menu is the settings surface. Open at login stays off until you turn it on.

The clock on the left of the notch is a simple timer. Use it to track focus, or to see how long a task takes. It is experimental, v1. Click the clock to start. The center then shows whole minutes. Pause and stop are on that same wing.

## What you need

- macOS 12 or later
- A Mac with Touch Bar hardware

The OLED can be black. The private Touch Bar framework still has to be on the machine. Quit Touché first if you use it. Both apps talk to the same simulator and they get in each other's way.

## Install

There is no auto-update yet. When a new build is out, download it the same way.

1. Download `TouchBarPill-0.5.6.zip` from Releases.
2. Unzip it and open `TouchBarPill.app`.
3. If macOS says the app is from an unidentified developer, right-click `TouchBarPill.app`, choose Open, then Open again.

## Brightness and volume

With the mirror open, scroll on the brightness sun or the volume speaker in the Control Strip.

- Right or up raises the level.
- Left or down lowers it.

The notch has its own volume wing. Scroll there the same way.

## Private system frameworks

TouchBarPill loads Apple's private DFRFoundation and DisplayServices frameworks at runtime so it can mirror the Touch Bar and change built-in brightness. Those calls are not public API. A macOS update can break the mirror or the brightness control without warning. This project is not affiliated with Apple.

Support is best effort.

## Build from source

Command Line Tools are enough. The script ad-hoc signs the app.

```sh
./build-cli.sh
open build/TouchBarPill.app
```

## License

MIT. See [LICENSE](LICENSE).
