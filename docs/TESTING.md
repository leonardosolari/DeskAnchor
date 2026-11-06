# Testing

Run the automated suite with:

```sh
make test
```

The suite covers display identity and geometry, monitor arrangement planning and validation, window matching, partial updates, backup, migration and asynchronous state polling. It does not reconfigure real displays or move or hide real windows.

The display-arrangement branch passes 39 automated tests, including 13 arrangement cases: the office monitor above/right scenario, negative coordinates, a different primary display, unchanged or disabled arrangements, missing/replaced/additional monitors, resolution/rotation changes, invalid imports, legacy archives, export round trips and desktop-only update preservation. These exercise the pure planner; the native Quartz transaction still requires the hardware checks below.

## Integration status

Development checks on macOS 15.8.1 have covered the following:

- Native Spaces inventory and Accessibility permission reporting.
- Saving a workspace across multiple desktops and returning to the original Space.
- JSON persistence and GUI/CLI communication.
- Direct navigation to all four settings pages, new-layout cancellation and keyboard commands.
- Avoiding unchanged permission publications that would rebuild an open status menu.

These checks do not establish compatibility with every application, display configuration or macOS release. Intel binaries are cross-compiled; execution on an Intel Mac still needs separate verification.

## Build verification

The publication setup has been checked from a fresh source-only directory:

- `make test`: 26 tests passed, including legacy archive migration, archive precedence and preservation.
- `make release`: both GUI and CLI contain `arm64` and `x86_64` slices.
- Bundle version and build number match the build inputs.
- The release ZIP passes integrity and SHA-256 checks.
- The extracted application retains valid signatures and executable permissions; the CLI help and GUI preview smoke test run successfully.
- Generated and local directories are excluded from the Git source set.

The GitHub workflow uses these same commands. A hosted Actions run still needs to be verified after the repository is uploaded.

## Manual matrix

Use test windows with saved content when checking window-management behavior.

| Area | Check |
| --- | --- |
| Capture | Entire workspace, visible desktops, active desktop; hidden and minimized windows |
| Restore | Geometry, stacking, native desktop assignment, focused-window restoration |
| Multiple windows | Duplicate titles, renamed documents and relaunching the same application |
| Exclusions | Global and per-layout exclusions during capture, launching, restore and visibility changes |
| Updates | Full updates, active-desktop-only updates, preservation on incomplete capture |
| Displays | Two monitors, reordered monitors, undocking and a missing saved display |
| Arrangement | Save an external monitor to the right, move it above in System Settings, restore and verify both monitor and window positions |
| Primary display | Save an external primary display with the Mac to its left, change the primary, then restore |
| Arrangement controls | Disable restoration, save only the setup on an old layout, export/import and update only the active desktop |
| Arrangement fallback | Disconnect a display, attach an additional/replacement display, change scaling/rotation or enable mirroring; verify a warning and window adaptation |
| Arrangement automation | Reconnect with automatic restore enabled; verify one restore without repeated screen-change loops; focused-window restore must leave screens alone |
| Spaces | Creating missing desktops, optional removal, restoring to new/visible desktops |
| Window constraints | Minimum sizes, unexposed AX windows and nonstandard title bars |
| State | Hidden applications, minimized windows and simulated fullscreen |
| Automation | Login, wake, display changes and cancellation during an operation |
| Menus | Keep each submenu open across several permission-polling intervals |
| Packaging | Universal binaries, version metadata, ZIP contents, checksum and executable permissions |

Test with one automatic window organizer at a time. Cross-version and external-display validation remains ongoing.
