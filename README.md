# DeskAnchor

**Save your workspace. Find your way back.**

DeskAnchor is an open-source macOS menu bar app that saves and restores window layouts across native Spaces and displays. Built with Swift and SwiftUI, with local storage, no accounts and no telemetry.

Early release. macOS Spaces support uses private APIs, so compatibility can vary between macOS versions and applications.

## Features

- Save an entire workspace, the visible desktops or the active desktop.
- Restore window positions, sizes and visibility across multiple displays.
- Restore onto saved, visible or new desktops, with optional application launching.
- Update a complete layout or just the active desktop.
- Exclude applications globally or per layout.
- Rename, duplicate, edit, import and export layouts.
- Assign keyboard shortcuts to layouts and common actions.
- Optionally restore after a display change or wake, and launch at login.
- Control layouts from the included `deskanchor` command-line client.

## Requirements

- macOS 13 or later, on Apple Silicon or Intel.
- Accessibility permission to manage other applications' windows.
- To build: Xcode 15 or later with its command-line tools selected. No external package dependencies.

## Build and run

From the repository root:

```sh
make
open build/DeskAnchor.app
```

Or use `make run`. The default build targets your current Mac. For both Apple Silicon and Intel:

```sh
UNIVERSAL=1 make
```

Copy `build/DeskAnchor.app` into Applications if you want to keep it installed. You can also open `Package.swift` in Xcode for development.

| Command | Result |
| --- | --- |
| `make` | Build the app for the current architecture |
| `make run` | Build and open the app |
| `make test` | Run the automated tests |
| `make release` | Build a universal app and create a ZIP plus SHA-256 checksum |
| `make clean` | Remove generated build and distribution files |

## Build on GitHub

The **Build DeskAnchor** workflow runs on pushes to `main`, pull requests and manual requests:

1. Open **Actions → Build DeskAnchor → Run workflow**.
2. Select the branch and start the workflow.
3. Download **DeskAnchor-macOS** from the completed run's artifacts.
4. Extract the artifact to obtain the application ZIP and its checksum.

No certificates, secrets or release permissions are required. The workflow runs the same `make test` and `make release` commands as a local build. It does not create releases or publish files automatically.

## Prepare a release

Set the desired `X.Y.Z` version in [VERSION](VERSION), then:

```sh
make release
```

The files ready for manual upload to a GitHub Release are:

```text
dist/DeskAnchor-0.1.0-macos-universal.zip
dist/DeskAnchor-0.1.0-macos-universal.zip.sha256
```

The version in the filenames and application bundle comes from `VERSION`. You can override it for a build with `VERSION=0.2.0 make release`. `BUILD_NUMBER` optionally overrides the internal build number; GitHub Actions uses its run number.

Verify a download with:

```sh
shasum -a 256 -c DeskAnchor-0.1.0-macos-universal.zip.sha256
```

Only source files belong in Git. `.build/`, `build/`, `dist/` and `.local/` are ignored, and the workflow rejects committed files in these directories.

### Signing

Builds use ad hoc signing by default. These binaries are not notarized, and macOS may require explicit approval before opening a downloaded application. Building from source is also supported.

To use an installed signing certificate:

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make release
```

This signs the application locally; it does not notarize or upload it. Reuse the same signing identity and bundle identifier across updates to retain a consistent application identity. Ad hoc builds may require Accessibility permission to be renewed after an update.

## Getting started

1. Open DeskAnchor and allow it in **System Settings → Privacy & Security → Accessibility**.
2. Disable automatic rearrangement of Spaces in **Desktop & Dock → Mission Control** so desktop ordering stays predictable.
3. Keep the **Control–Left/Right Arrow** Mission Control shortcuts enabled. They are used as a fallback when macOS rejects a direct window move.
4. Arrange your windows, choose **Salva nuovo layout…**, and give the layout a name.
5. Use **Ripristina layout** to apply the saved arrangement, or **Aggiorna salvataggio** to replace it with your current arrangement.

The interface is currently in Italian. Settings pages are directly accessible from the sidebar. **⌘N** opens a new layout; **⌘,** opens settings. Additional restore modes and focused-window actions are grouped under **Altre azioni** in the menu bar.

If the Accessibility switch is enabled but access is still denied, quit DeskAnchor, remove its existing entry from Accessibility, add the current application again, then reopen it. **Mostra questa app** in the permission banner locates the exact bundle.

## Command line

The client is included in the application bundle:

```sh
build/DeskAnchor.app/Contents/MacOS/deskanchor --help
build/DeskAnchor.app/Contents/MacOS/deskanchor --list
build/DeskAnchor.app/Contents/MacOS/deskanchor --create "Development" --scope=workspace
build/DeskAnchor.app/Contents/MacOS/deskanchor --restore "Development"
build/DeskAnchor.app/Contents/MacOS/deskanchor --restore-active --launch-apps=false
build/DeskAnchor.app/Contents/MacOS/deskanchor --update-active-desktop
```

DeskAnchor must be running for commands other than `--list` and `--help`. The client waits for completion and returns a nonzero exit code on failure. `--diagnostics` reports display and permission information; `--capture-diagnostics` reads the initial window inventory without switching desktops or saving a layout.

## Local data

Layouts and preferences are stored in:

```text
~/Library/Application Support/DeskAnchor/library.json
```

Writes are atomic. `library.json.backup` contains the previous version. Exported JSON includes window titles, application identifiers and paths, geometry and desktop assignments.

On first launch, DeskAnchor copies a supported earlier development archive if no new archive exists. The previous archive is preserved. Subsequent launches use the new archive. A renamed application needs its own Accessibility approval.

## Limitations

- Closed documents, projects, browser tabs and individual windows are not recreated. DeskAnchor can launch an application and position windows it exposes.
- Stage Manager is not supported. Native fullscreen windows are restored in a simulated fullscreen arrangement on an ordinary desktop.
- Applications can impose size constraints or expose incomplete Accessibility information. Missing windows and partial captures are reported; incomplete updates preserve the previous layout.
- The fallback for moving windows between Spaces temporarily uses the pointer. Wait for completion or cancel the operation from the app.
- Windows assigned to all desktops keep their current assignment; DeskAnchor does not recreate Dock pinning settings.
- Multi-display behavior and private Spaces APIs need testing across macOS versions. See [testing notes](docs/TESTING.md).

## Development

`WorkspaceCore` contains the models, matching, geometry and persistence. `DeskAnchorApp` contains the native interface and window-management services. `DeskAnchorCLI` is the command-line client. See [architecture](docs/ARCHITECTURE.md) for details.

Tests do not move real windows. For a visual preview using sample layouts without writing an archive:

```sh
open -n build/DeskAnchor.app --args --preview
```

If your development environment cannot run SwiftPM's nested sandbox, set `DESKANCHOR_DISABLE_PACKAGE_SANDBOX=1` when invoking `make` or `make test`. This affects package compilation only.

## License

[MIT](LICENSE).
