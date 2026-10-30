# Architecture

DeskAnchor is a native macOS application built as a Swift package, without external dependencies.

- **WorkspaceCore**: Codable layout models, display mapping, one-to-one window matching, asynchronous state polling and atomic JSON storage.
- **DeskAnchorApp**: SwiftUI window and menu bar interface, navigation, global shortcuts, application launching, Accessibility capture and restore orchestration.
- **DeskAnchorCLI**: a synchronous client that sends UUID-scoped requests to the GUI process and waits for a response. The GUI process holds Accessibility permission.

## Capturing and restoring

Displays are identified by UUID. Window frames are recorded in the coordinate system used by Accessibility; normalized geometry supports layouts with different display sizes or missing monitors.

Window matching prefers a window ID from the same application launch, followed by AX identifiers, titles and application-local order. Assignments are one-to-one. Applications remain responsible for reopening their own documents and windows.

Spaces inventory uses optional SkyLight symbols resolved at runtime. Mission Control's Accessibility interface creates, removes and selects desktops. Transitions are verified by observing the actual active Space. Window movement tries an available native API, then a title-bar drag with Control–Arrow navigation. SIP is not modified.

Some applications expose windows only on their active desktop. Capture can visit relevant Spaces and then return to the original desktop. Additional scan failures produce a partial capture; an incomplete update keeps the previous layout.

The macOS integration is isolated in `SpacesService.swift` and `Accessibility.swift`. Public implementation references include [Hammerspoon Spaces](https://github.com/Hammerspoon/hammerspoon/tree/master/extensions/spaces) and [DockDoor's private API declarations](https://github.com/ejbills/DockDoor/blob/main/DockDoor/Utilities/PrivateApis.swift).

## Persistence and compatibility

`LibraryStore` validates JSON before writing it, uses atomic replacement and preserves a previous-version backup. The GUI can copy a supported legacy development archive into the new directory on first launch. Migration never changes the source archive or overwrites an existing destination. The CLI's fallback read does not write files.

## Build outputs

`make` assembles `build/DeskAnchor.app`; `make release` builds both architectures and packages the bundle into a versioned ZIP in `dist/`. A staged bundle is signed and verified before replacing a previous build. Packaging uses `ditto` to preserve bundle metadata and executable permissions.

GitHub Actions uses the same commands as a developer. It requires no signing secrets and uploads only the ready-to-distribute ZIP and checksum as workflow artifacts. Publishing a GitHub Release remains a manual step.
