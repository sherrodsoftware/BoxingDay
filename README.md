# Boxing Day

A small open-source macOS utility that turns an app into a Jamf Pro–ready installer
package. Drop in a `.app`, `.dmg`, or `.zip`; get back a `.pkg` that installs
the app to `/Applications` with the correct ownership and permissions. You can
also select an existing `.pkg` for upload to Jamf Pro.

## What it does

1. **Accepts a dropped file** — `.app`, `.dmg`, `.zip`, or `.pkg`.
   Files can also be selected with the **Choose File** button.
2. **Resolves it down to an `.app` bundle**:
   - A `.app` is used as-is.
   - A `.zip` is extracted (via `ditto`) and searched recursively for an app.
   - A `.dmg` is mounted (via `hdiutil`), searched recursively, and the app
     inside is copied out before the disk image is unmounted.
   - Helper apps nested inside a discovered app are ignored. If multiple
     outer apps are found, Boxing Day lists them and asks for an archive
     containing one app instead of silently choosing one.
   - An existing `.pkg` skips the build step and can be uploaded to Jamf Pro.
3. **Reads the app's own `Info.plist`** to pre-fill a sensible package
   identifier (`<bundle id>.pkg`) and version number, both editable before
   building. The selected app's icon, name, and code-signature status are
   displayed, and invalid identifier or version values are explained before
   the build can start.
4. **Stages a clean copy of the app**, sets the top-level `.app` directory to
   `755` while preserving the developer's permissions for all enclosed items,
   and recursively removes only `com.apple.quarantine` while preserving every
   unrelated extended attribute (see "Why quarantine gets stripped" below).
5. **Verifies the staged app's code signature** when the source signature is
   valid. Packaging stops if staging damages a valid signature. A source app
   that is already unsigned or invalid can still be packaged with a warning.
6. **Builds the `.pkg`** via `pkgbuild`, using `--ownership recommended` so
   the app and all enclosed files end up owned by `root:wheel` — matching
   what Jamf Pro and macOS expect for an app in `/Applications` — without
   requiring this app to run as root or prompt for `sudo`. Boxing Day also
   supplies component metadata with bundle relocation disabled, ensuring
   Installer uses the package's explicit `/Applications` destination instead
   of updating another copy found elsewhere on disk.
7. **Prompts for a save location**, suggesting a filename that includes
   the app name and version (e.g. `Super App 1.234.5.pkg`). After success or
   failure, the resolved app remains available to build again or retry without
   repeating extraction or disk-image mounting. The completion summary shows
   the saved filename and location, package identifier, version, install
   location, package size, signature warning (when applicable), and a
   **Reveal in Finder** button.
   Build and upload errors can also be saved as plain-text reports.
8. **Cleans up its temporary workspaces** after errors, replacement drops,
   build attempts, window closure, and normal app termination. Workspaces
   abandoned by a crash or force quit are detected and removed on a later
   launch without disturbing another running instance.
9. **Stores an optional Jamf Pro connection** in **Boxing Day > Settings**.
   Each organization supplies its own Jamf Pro URL, API client ID, and API
   client secret. The secret is stored in the macOS Keychain. **Save & Test
   Connection** verifies OAuth authentication, package and category read
   access, and cloud distribution point access without creating or modifying
   Jamf objects. The Settings pane can also load the server's categories and
   save a user-selected default category for future uploads.
10. **Uploads completed packages to Jamf Pro** after an explicit review.
    Boxing Day checks for an existing filename, creates the Jamf package
    record, uploads the file with progress, and waits for cloud processing to
    complete. Existing filenames are blocked rather than silently replaced.

## Jamf Pro connection

Boxing Day uses Jamf Pro API client credentials so it can work with any
organization's Jamf Pro tenant without embedding tenant-specific information.
Create and enable an API client assigned to a role with:

- Create Packages
- Read Packages
- Update Packages
- Read Cloud Distribution Point
- Read Categories

Enter the Jamf Pro server URL, client ID, and client secret in
**Boxing Day > Settings** (`Command-,`). Server and client identifiers are
stored in app preferences; the client secret is stored only in this Mac's
Keychain. Access tokens are requested as needed and are not persisted. The
connection controls save and test these credentials; the **Default Category**
picker saves its selection immediately.

After a successful local build, click **Upload to Jamf Pro…** to review the
package name, filename, category, priority, and notes. Boxing Day loads the
category names from Jamf Pro. A new connection starts with **No Category**;
choose a default category in Settings or select a different category for a
specific upload. The most recently selected category is remembered. During
upload, an activity trail shows authentication, duplicate checking, record
creation, file-transfer progress, and Jamf's cloud status. A `READY` cloud
status completes the workflow, and an expired token during status checking is
renewed once automatically. The local package remains available even if Jamf
authentication, upload, or cloud processing fails. If Jamf creates a package
record before a later failure, Boxing Day reports its package ID so the partial
record can be found.

## Why quarantine gets stripped

Files downloaded from the internet (inside the original `.dmg`/`.zip`) carry
a `com.apple.quarantine` extended attribute. Plain file copies preserve
that attribute by default, and if it survives into the built `.pkg`, the
installed app can end up subject to **App Translocation** — macOS silently
running it from a hidden, randomized path instead of its real location in
`/Applications`, even though Finder shows it sitting there normally. Some
apps detect this and show a spurious "please move me to Applications"
prompt, because as far as the app can tell at runtime, it isn't *really*
in `/Applications`. Removing `com.apple.quarantine` recursively from the
staged copy before packaging avoids this without discarding unrelated
extended attributes supplied by the app developer.

## Requirements

- macOS 15 or later (Mac-only app — no iOS/iPadOS/visionOS target)
- Xcode 26 or later to build from source

## License

Boxing Day is available under the [MIT License](LICENSE.md).

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before
opening an issue or pull request.
