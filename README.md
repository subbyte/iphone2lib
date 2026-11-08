# Import iPhone Photo/Video to Library

Import media from an iPhone `DCIM` directory into a file-system-based library.

## Library Organization

Files are copied to `Year/Month/YYYYmmdd-HHMMSS-<checksum>.ext`:
- Timestamp: first valid `CreationDate`, `DateTimeOriginal` or `CreateDate`
  (via `exiftool`); if none, the latest timestamp seen so far
- Live Photo videos take the timestamp of their paired still
- Checksum: first 8 hex chars of the file's SHA-1
- Extension: original, lowercased

Supported: heic heif jpg jpeg dng png gif tif tiff webp mov mp4 m4v.
Duplicates (same full SHA-1) are not copied again, so re-running is safe.
Other files, symlinks, nested subdirectories and loose files in `DCIM/`
are skipped with a warning.

## Requirements

- `exiftool`

## How to use

1. Mount your phone, e.g., using `ifuse`
2. Locate `DCIM` in the mounted directory
3. `iphone2lib DCIM_dir lib_dir >i2l.log 2>i2l.err`
4. Track the status with `tail -f i2l.log`
5. Check warnings in `i2l.err`
