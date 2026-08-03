# CueMirror

CueMirror is an experimental macOS utility that converts djay Pro Hot Cues 9–16 on a OneLibrary USB drive into Memory Cues that compatible CDJ/XDJ hardware can recognize.

> CueMirror is still in testing. Back up your USB drive data before using it.

## Current support

- macOS 15.2 or later on Apple silicon
- English and Simplified Chinese, selected automatically from the macOS language settings
- OneLibrary USB drives exported by djay Pro
- FLAC tracks with point cues in Hot Cue slots 9–16
- Batch selection by playlist or track

CueMirror preserves Hot Cues, but replaces all existing Memory Cues on each selected track. Hot Cue loops and non-FLAC audio are currently skipped.

## Using CueMirror

1. Install [Homebrew](https://brew.sh) if needed, then install Python 3.14:

   ```sh
   brew install python@3.14
   ```

2. Back up the USB drive.
3. Open CueMirror and select the root of the OneLibrary drive.
4. Review the scan results and select tracks or playlists.
5. Confirm the replacement operation.
6. Safely eject the drive and verify it on compatible hardware before relying on it for a performance.

If Python 3.14 is missing, CueMirror displays the same installation command in the app. Python is used only for the read-only SQLCipher database query; CueMirror works on a temporary copy and does not connect directly to the database on the USB drive.

## Building

Open `CueMirror.xcodeproj` in Xcode 16.2 or later and build the `CueMirror` scheme. The current database reader also requires Homebrew Python 3.14, normally installed at `/opt/homebrew/bin/python3.14`.

For a local Release archive:

```sh
./scripts/build-release.sh
```

The archive is written to `dist/`. GitHub Actions also builds the same artifact when a tag matching `v*` is pushed. Release artifacts are ad-hoc signed, but are not notarized by Apple.

## Versioning

The user-facing version comes from Xcode's `MARKETING_VERSION`; the build number comes from `CURRENT_PROJECT_VERSION`. CueMirror displays both directly from its app bundle. For a new release, update both values, commit the change, and create a matching tag such as `v0.1.0`.

## Tests

The parser and conversion planner have self-contained unit tests. Hardware and FLAC integration tests are skipped when their local fixtures are unavailable.

## Disclaimer

This project is unofficial and is not affiliated with or endorsed by Algoriddim, AlphaTheta, Pioneer DJ, or rekordbox. It modifies files on removable media and is provided without warranty. Use it only on data you can restore.

## License

MIT. See [LICENSE](LICENSE).
