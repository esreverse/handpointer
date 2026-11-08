<img src="./.github/logo.png" width="80" />

# TinyPointer

[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey)](https://github.com/esreverse/tinypointer)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

A tiny hand on a stick that points at things on your Mac screen, with rainbow ink and a zoom loupe.

TinyPointer is developed by [Eric Singhartinger](https://github.com/esreverse) and is based on
[TinyHand](https://github.com/nilbuild/tinyhand) by Kamran Ahmed, used under the MIT License.

macOS 13 or later, Apple Silicon and Intel.



## Build

```bash
scripts/build-local.sh --install
```

Builds TinyPointer, replaces `/Applications/TinyPointer.app` and starts it. Allow **Accessibility** when
asked, so clicks become taps, and **Screen Recording** for the zoom loupe.



## Use

| | |
|---|---|
| Click the menu bar icon, or **⌃⇥** | Turn the pointer on or off |
| Right-click the menu bar icon | Menu and Settings |
| Click | Tap (nothing underneath gets clicked) |
| Hold and drag | Draw on the screen |
| Hold **⇧** | Zoom loupe |
| Hold **⌃** | Click the app underneath for real |
| **⇥** | Clear the drawing |
| **T** | Show or hide the toolbar |
| **Esc** | Clear everything and turn the pointer off |

Keys without ⌃, ⌥ or ⌘ only work while the pointer is on. All shortcuts can be changed in Settings.



## License

MIT. See [LICENSE](LICENSE).
