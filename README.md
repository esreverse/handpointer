<img src="./.github/logo.png" width="80" />

# TinyPointer

[![Latest release](https://img.shields.io/github/v/release/esreverse/tinypointer?display_name=tag&sort=semver)](https://github.com/esreverse/tinypointer/releases/latest)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS_13+-lightgrey)](https://github.com/esreverse/tinypointer/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

A tiny hand on a stick that points at things on your Mac screen, with rainbow ink, a tap circle and a zoom loupe.

[![Download for macOS](https://img.shields.io/badge/Download_for_macOS-000000?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/esreverse/tinypointer/releases/latest/download/TinyPointer.dmg)

macOS 13 or later, Apple Silicon and Intel. Earlier versions and release notes are on the
[Releases](https://github.com/esreverse/tinypointer/releases) page.



## Install

1. Download **TinyPointer.dmg** with the button above.
2. Open it and drag TinyPointer to **Applications**.
3. Open TinyPointer. The first time, macOS says it can't check the developer, because the app is not
   notarized yet. Go to **System Settings → Privacy & Security** and click **Open Anyway**.
4. Allow **Accessibility** when asked. TinyPointer needs it to turn your clicks into taps and to let you draw.
5. For the zoom loupe, turn on Zoom in Settings and allow **Screen Recording**.

TinyPointer updates itself: new versions are checked and installed automatically. You can also check
by hand in **Settings → General**.



## Use

| | |
|---|---|
| Click the menu bar icon, or **⌃⇥** | Turn the pointer on or off |
| Right-click the menu bar icon | Menu and Settings |
| Click | Tap (nothing underneath gets clicked) |
| Hold and drag | Draw on the screen |
| Hold **⌃** | Click your Mac for real |
| **Q** | Clear the drawing |
| **A** / **R** | Automatic colour / rainbow colour |
| **X** / **Y** | Next / previous pointer (hold to step through) |
| **H** | Show or hide the toolbar |
| **M** | Sound on or off |
| **⌘,** | Settings |
| **Esc** or right-click | Clear everything and turn the pointer off |

Single keys only work while the pointer is on. All shortcuts can be changed in **Settings → Shortcuts**.
The zoom loupe is off at first; turn it on in **Settings → Zoom** and hold **⇧** to zoom.



## Build From Source

For development only; to just use TinyPointer, download the DMG above.

```bash
scripts/build-local.sh --install
```

This compiles TinyPointer from the source code, signs it with a local certificate, replaces
`/Applications/TinyPointer.app` and starts it.

```bash
scripts/release.sh --skip-notarize
```

This builds the DMG and the update feed for a release into `dist/release/`. The release notes come from
[CHANGELOG.md](CHANGELOG.md).



## Credits

TinyPointer is developed by [Eric Singhartinger](https://github.com/esreverse). It is based on
[TinyHand](https://github.com/nilbuild/tinyhand) by Kamran Ahmed, used under the MIT License.



## License

MIT. See [LICENSE](LICENSE).
