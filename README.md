# CueMirror

CueMirror is an experimental macOS utility that converts djay Pro Hot Cues 9–16 on a OneLibrary USB drive into Memory Cues that compatible CDJ/XDJ hardware can recognize.

> CueMirror is still in testing. Back up your USB drive data before using it.

## Screenshots

Select the root of the OneLibrary USB drive—do not select its `PIONEER` or `USBANLZ` subfolder.

![Selecting the root of a OneLibrary USB drive in CueMirror](docs/images/select-onelibrary-usb.png)

Review the selected tracks and projected changes before confirming the Memory Cue replacement.

![CueMirror confirmation before replacing Memory Cues on the USB drive](docs/images/confirm-memory-cue-replacement.png)

## Current support

- macOS 15.2 or later on Apple silicon
- OneLibrary USB drives exported by djay Pro
- FLAC using the hardware-verified conversion path
- Experimental WAV, AIFF, and MP3 support through an opt-in setting (audio locating is tested in software; CDJ hardware results need community testing)
- Point cues in Hot Cue slots 9–16
- Batch selection by playlist or track

CueMirror preserves Hot Cues, but replaces all existing Memory Cues on each selected track. Hot Cue loops are currently skipped. Non-FLAC tracks are skipped unless the experimental audio formats setting is explicitly enabled.

## Using CueMirror

1. Install [Homebrew](https://brew.sh) if needed, then install Python 3.14:

   ```sh
   brew install python@3.14
   ```

2. Back up the USB drive.
3. Open CueMirror and select the root of the OneLibrary drive.
4. Review the scan results and select tracks or playlists.
5. For WAV, AIFF, or MP3 tracks, enable **Experimental WAV / AIFF / MP3**. Leave it off for the verified FLAC-only path.
6. Confirm the replacement operation. CueMirror shows an additional warning when experimental tracks are included.
7. Safely eject the drive and verify it on compatible hardware before relying on it for a performance.

If Python 3.14 is missing, CueMirror displays the same installation command in the app. Python is used only for the read-only SQLCipher database query; CueMirror works on a temporary copy and does not connect directly to the database on the USB drive.

Experimental formats are located only when selected tracks are prepared for writing; adding more recognized formats does not make the normal USB scan slower. WAV and AIFF use macOS packet metadata, while MP3 frames are parsed once per track and reused for all its cues. These paths have automated software tests but still require reports from real CDJ/XDJ hardware.

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
