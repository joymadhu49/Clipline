# Clipline

[![CI](https://github.com/joymadhu49/Clipline/actions/workflows/ci.yml/badge.svg)](https://github.com/joymadhu49/Clipline/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/joymadhu49/Clipline?label=download)](https://github.com/joymadhu49/Clipline/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="Clipline icon" />
</p>

A native macOS clipboard manager. Clipboard history, pinned entries, instant search, and a popup panel on a global shortcut. Written in Swift on the system frameworks plus [Sparkle](https://sparkle-project.org) for updates, and built to stay small in both memory and disk.

Installed at `/Applications/Clipline.app`. Runs in the menu bar with no Dock icon.

## What it does

- **History.** Everything you copy is recorded: plain text, rich text, links, colour codes, images and copied files. Duplicates fold into the entry you already have instead of piling up.
- **Pinning.** Pin any entry with Command P. Pinned entries sit at the top of the list and are never trimmed away by the history limit or the retention window.
- **Popup panel.** Press Command Shift V anywhere. The panel opens over whatever you are working in, with the search field already focused.
- **One narrow column.** The list is the whole interface, the way CopyQ does it. No detail pane, no full text view, nothing to cover your work. It carries the standard close and minimize buttons, moves by its top bar, and resizes from any edge. Neither the list nor the settings window has a scroll bar down the side; the wheel and the trackpad do the work.
- **It stays where you put it.** Drag the panel somewhere and that is where it opens from then on, at the size you dragged it to. The drag also settles Settings > Appearance > Panel appears on "Where you left it", so a spot you chose by hand is never quietly overruled by a preset. If the display it was on is gone, or the spot no longer holds most of the panel, it falls back to the middle of the screen the pointer is on rather than opening half off the edge. Settings > Appearance has a Reset size and position button for when you want the preset back.
- **Search when you want it.** The search field is hidden by default so the panel stays quiet. Press Command F or click the magnifier to bring it out, Esc to put it away. Settings can keep it on permanently.
- **Filters.** Chips narrow the list to pinned, text, links, images or files.
- **Hard to lose things.** Pinned entries cannot be deleted until you unpin them, and every deletion is written to an audit log.
- **Safe on a shared screen.** The panel is invisible to screen recording, streaming and screen sharing (Settings > Privacy, on by default) — you see it, viewers never do. On top of that, any entry can be masked with ⌘H: it keeps pasting as normal, but the list shows a name you give it ("Email", "Password") or dots instead of the content, with no thumbnail, source app or size to give it away.
- **Paste back.** Return pastes the selected entry into the app you were just in. Option Return pastes it without formatting, Command Return copies without pasting.
- **Keeps itself current.** New versions arrive through [Sparkle](https://sparkle-project.org): Clipline checks GitHub once a day, and each update is verified against an EdDSA signature and Apple's notarization before it installs. Settings > About turns the daily check off, and the menu bar menu has Check for Updates… for when you want it now.
- **Settings.** A full settings window covering behaviour, shortcuts, history limits, appearance and privacy. Named groups, one rule in the whole window, and each group's action in its own heading rather than floating in the gap below it.

## Install

Requires macOS 14 or later. Runs on both Apple silicon and Intel.

### Download

1. Take the latest `.dmg` from the [Releases](https://github.com/joymadhu49/Clipline/releases/latest) page.
2. Open it and drag **Clipline** into `/Applications`.
3. Launch it. The icon appears in the menu bar; there is no Dock icon and no window until you ask for one.
4. macOS asks for Accessibility access on first launch. Grant it, or see [Permissions](#permissions) for what you lose without it.

Release DMGs are signed with a Developer ID certificate and notarized by Apple, so
they open normally: no "damaged, move to Trash" prompt and no right-click workaround.

### Build it yourself

See [Build](#build) below. One script, and the result is the same universal, hardened-runtime app the release pipeline ships.

## Keys

Global, and rebindable in Settings > Shortcuts:

| Shortcut | Action |
| --- | --- |
| ⌘⇧V | Open the clipboard panel |
| ⌥⇧⌘P | Open the panel filtered to pinned entries |

Inside the panel:

| Key | Action |
| --- | --- |
| ↑ ↓ | Move through the list |
| return | Paste the selected entry |
| ⌥ return | Paste without formatting |
| ⌘V | Paste the selected entry, same as return |
| ⌘ return or ⌘C | Copy without pasting |
| ⌘1 to ⌘9 | Paste that numbered row |
| ⌘P | Pin or unpin |
| ⌘H | Hide or show the entry's content in the list |
| ⌘⌫ | Delete the entry, unless it is pinned |
| ⌫ | Also deletes, while the search field is away |
| ⌘F | Show or hide the search field |
| tab | Next filter, shift tab for the previous one |
| ⌘O | Open a link, or reveal a file in Finder |
| ⌘, | Open settings |
| esc | Clear the search, then close |

Click a row to paste it. Moving the pointer over a row selects it, so the delete and pin keys act on the entry under the mouse; a keyboard scroll sliding rows under a resting pointer does not steal the selection back. Hovering a row also reveals pin and delete buttons, right click gives the full action menu, and rows can be dragged straight into another app.

Drag the header to move it, drag any edge to resize it. The panel then keeps that exact frame: a layout pass is not allowed to nudge it smaller, which is what used to make it look like it shrank a little on every open.

**Images.** An image entry goes onto the clipboard as both PNG and TIFF, because apps disagree about which one they accept, so Command V works in Preview, Pages, Mail, Figma and the rest. Dragging an image row offers the file on disk and the raw bytes, so it drops into Finder as a file and into an editor as a picture.

## Permissions

Pasting into another app needs **Accessibility** access, because Clipline presses Command V on your behalf. macOS asks on first launch. If you skipped it, Settings > General has a button that opens the right pane in System Settings, and the panel shows a reminder bar until it is granted. Without it Clipline still copies to the clipboard, you just press Command V yourself.

No other permission is needed. Your clipboard never leaves the machine; the only network request Clipline makes is the daily update check to GitHub, which carries no clipboard data and no system profile.

## How it stays small

- **Memory.** List rows hold only a short preview and metadata. Full text, images and file lists are read from disk only for the entry you are actually looking at. Image previews are decoded at display size through `CGImageSourceCreateThumbnailAtIndex`, never at full resolution. The thumbnail cache is capped by count and cost and is emptied whenever you switch away from Clipline. Measured footprint in normal use is around 27 MB.
- **Disk.** Text over 32 KB, images and file lists live as files in the support folder, so the database itself stays tiny. Screenshots are re encoded from TIFF to PNG on capture. Duplicate copies never create a second row. The write ahead log is capped and checkpointed whenever the app goes idle.
- **CPU.** The poll timer reads a change counter and nothing else. Pasteboard contents are only touched when that counter moves, and hashing, thumbnailing and disk writes happen off the main thread. The timer carries a wide tolerance so the system can coalesce it with other work. Detection speed is configurable from 0.15 up to 1.5 seconds.
- **Growth.** A history limit (500 entries by default), an optional retention window from 3 hours to 90 days, and a size ceiling for a single entry (8 MB by default). Trimming deletes the stored files along with the row, runs on every capture and every few minutes in between, so a short window is honoured even while nothing is being copied, and there is a cleanup pass that also removes any file no row points at.

Everything lives in `~/Library/Application Support/Clipline`: `clipline.db`, `blobs/`, `thumbs/` and `audit.log`.

Deleting an entry removes the row and its stored files straight away, so the space comes back immediately; copying the content again recreates the entry. Every deletion is recorded in `audit.log` with a timestamp and the call site, so if history ever disappears there is a record of what removed it.

## Privacy

- Content an app marks as concealed, transient or auto generated is skipped. That is the flag password managers set, so passwords are not recorded.
- Copies made while an app on the ignore list is in front are never recorded. Keychain Access, 1Password and Bitwarden are on that list by default, and you can add any app.
- The panel window opts out of screen capture (`sharingType = .none`), so recordings, streams and screen shares never carry it. Can be turned off in Settings > Privacy.
- Masked entries (⌘H, or right click > Hide content) show a chosen name or dots in the list instead of what they hold. Right click > Name… labels an entry; the name also matches in search. Pasting, copying and pinning work unchanged.
- Optionally clear the history when Clipline quits. Pinned entries survive.

## Build

Requires Xcode and XcodeGen (`brew install xcodegen`). The one package, Sparkle, is
pinned in `project.yml` and fetched by Swift Package Manager during the build.

```sh
git clone https://github.com/joymadhu49/Clipline.git
cd Clipline
bash Scripts/build.sh
cp -R build/Clipline.app /Applications/
```

`Scripts/build.sh` owns the whole chain — icon, `xcodegen generate`, `xcodebuild`, then
codesign — and it is the same script CI and the release pipeline run, so a green CI badge
means the release build works. The result is a universal binary, because an arm64-only
build refuses to launch on the Intel Macs macOS 14 still supports.

Signing has two modes. With a Developer ID certificate in the keychain the script uses it,
with the hardened runtime and a secure Apple timestamp, which is both what notarization
requires and what keeps the Accessibility grant stable across rebuilds. Without one it
falls back to ad-hoc signing, which compiles and runs but re-asks for Accessibility on
every rebuild. `CLIPLINE_SIGNING_IDENTITY` overrides the choice, and `UNIVERSAL=0` drops
the second architecture for a faster iteration build.

The Xcode project is generated from `project.yml` and is not checked in, so edit
`project.yml` rather than the project file — anything done in Xcode's inspector is
overwritten on the next build.

The app icon is drawn in code, not checked in as art. `Scripts/make_icon.swift` holds the
geometry and every size is rendered from it:

```sh
bash Scripts/make-icon.sh      # -> Resources/AppIcon.icns and AppIcon.png
```

### Releasing

`project.yml`'s `MARKETING_VERSION` is the single source of truth for the version;
`Info.plist` picks it up through `$(MARKETING_VERSION)`. Bump it, merge to `main`, and
the release workflow does the rest: build, sign, DMG, notarize with Apple, tag, and a
GitHub Release with the DMG and a signed `appcast.xml` attached. A push to `main` without a version bump releases
nothing, so the bump is the only human step. Pushing a `v*` tag by hand still works too.

That needs seven repository secrets under Settings → Secrets and variables → Actions:

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_CERT_P12` | base64 of the exported "Developer ID Application" certificate |
| `DEVELOPER_ID_CERT_PASSWORD` | the password set when exporting that `.p12` |
| `KEYCHAIN_PASSWORD` | any random string, for the runner's temporary keychain |
| `AC_API_KEY_P8` | base64 of the App Store Connect API key `.p8` |
| `AC_API_KEY_ID` | that key's ID |
| `AC_API_ISSUER_ID` | that key's issuer ID |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle's EdDSA private key, exported with `generate_keys -x` |

Base64 a file with `base64 -i Certificates.p12 | pbcopy`. The App Store Connect key comes
from Users and Access → Integrations → Keys, role Developer or higher, and downloads
exactly once.

The same three scripts run locally when you want to cut a build by hand:

```sh
export AC_KEYCHAIN_PROFILE=clipline-notary
bash Scripts/build.sh                        # universal, Developer ID signed
bash Scripts/notarize.sh build/Clipline.app  # ticket stapled to the app
bash Scripts/make-dmg.sh                     # -> build/Clipline-<version>.dmg
bash Scripts/notarize.sh                     # ticket stapled to the DMG
bash Scripts/make-appcast.sh                 # -> build/appcast.xml, signed from the keychain
```

**Updates.** The app's `SUFeedURL` is `releases/latest/download/appcast.xml`, which GitHub
redirects to whichever release is newest, so publishing a release is what ships the
update; there is no separate feed to keep in step. `CFBundleVersion` follows
`MARKETING_VERSION` because that is the number Sparkle compares. The EdDSA public key is
`SUPublicEDKey` in `project.yml`; the private half is in the maintainer's login keychain
and the `SPARKLE_ED_PRIVATE_KEY` secret. Keep a backup (`generate_keys -x`): without it,
installed copies will refuse every future update. `build.sh` re-signs Sparkle's nested
code with the app's own Developer ID, innermost first, and drops the two XPC services
Sparkle only needs inside a sandbox.

Notarization runs twice on purpose. The DMG's ticket is what Gatekeeper reads when
someone opens the download, but an app dragged out of a DMG that was notarized alone
carries no ticket of its own and has to be checked against Apple over the network on
first launch. Stapling the app first, then building the DMG around it, means the copy
in `/Applications` verifies offline. `xcrun stapler validate` on the `.app` is how you
check: it says "does not have a ticket stapled to it" when this step is missing.

### QA hooks

```sh
open -a /Applications/Clipline.app --args -panel             # opens the panel on launch
open -a /Applications/Clipline.app --args -settings          # opens settings on launch
open -a /Applications/Clipline.app --args -copyNewest image  # stages the newest image on the
                                                             # clipboard, then check with
                                                             # osascript -e 'clipboard info'
open -a /Applications/Clipline.app --args -selfTestPanelFrame # opens the panel and writes the
                                                             # spot it was asked for, the spot
                                                             # it landed on and the screen
                                                             # layout to audit.log
open -a /Applications/Clipline.app --args -selfTestShot      # renders every settings section
open -a /Applications/Clipline.app --args -selfTestShot privacy   # or just the one
open -a /Applications/Clipline.app --args -selfTestShot panel     # the clipboard panel
```

`-selfTestShot` writes PNGs to `~/Library/Application Support/Clipline/shots/` at 2x. The app
draws its own view into a bitmap, so it works without a Screen Recording grant, which is the
only way to review the interface from a terminal that does not have one.

For the panel it is the only way full stop. The panel excludes itself from screen capture, so
a screen recording of it comes back with a hole where the panel was — `-selfTestShot panel` is
how you get a picture of it without turning that protection off in Settings > Privacy.

`open -a` hands its arguments to a **new** process. If Clipline is already running, macOS
activates the existing instance and drops the arguments, so run the binary directly instead:

```sh
/Applications/Clipline.app/Contents/MacOS/Clipline -selfTestShot panel
```

Placement is worth checking with that last one after any change to the panel window, because a
frame that drifts by a few points on each open only shows up as a creep over several launches:

```sh
grep selfTestPanelFrame ~/Library/Application\ Support/Clipline/audit.log | tail -3
```

## Layout

```
Sources/App       main, AppDelegate, menu bar item, UpdateController (Sparkle)
Sources/Core      ClipItem, ClipStore (SQLite), ClipboardMonitor, PasteEngine,
                  SettingsStore, HotkeyCenter, Shortcut, Theme, ViewSnapshot
Sources/Panel     ClipPanel (NSPanel), PanelModel, ClipPanelView, ClipRowView
Sources/Settings  SettingsWindow, SettingsView, ShortcutRecorder
```

## Why not the Mac App Store

Pasting works by pressing ⌘V into the app you were just in, which means posting a keyboard
event with `CGEventPost`. A sandboxed process cannot post events into another process, and
the App Sandbox is mandatory on the Mac App Store, so a store build of Clipline would be a
clipboard manager that cannot paste. It ships outside the store instead: Developer ID
signed, notarized by Apple, and downloaded from Releases. `Clipline.entitlements` is an
empty dict for the same reason — nothing here needs an entitlement, only the Accessibility
grant.

## License

[MIT](LICENSE). Copyright 2026 Joy Madhu.
