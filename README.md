# Import iPhone Photo/Video to Library

Import media from an iPhone `DCIM` directory into a file-system-based library.

## How It Works

`iphone2lib` runs preparation and importing steps:

#### Preparation

Read the source (`DCIM` directory), index the destination (existing files in
the library) to avoid duplicates from source. Only directories/files explained
in the [Library Organization](#library-organization) are indexed, not
including `.cache/`, `.Trash/`, etc.

#### Importing

Two passes over the source, so a Live Photo video pairs with its still no
matter which of the two is seen first:

1. **Index Live Photos.** Read metadata headers from every still in each
   `DCIM/NNNAPPLE/`, recording `ContentIdentifier -> timestamp`.
2. **Import.** For each file: stage a copy to a temporary directory, read its
   timestamp and `ContentIdentifier`, resolve the final timestamp (pass-1
   pairing for videos), hash it, then copy it to its canonical name unless the
   same content is already in the library.

Pass 1 reads only headers, so the source bytes are read once in total: the
staging copy in pass 2. Imports are also deduplicated against each other, so a
file repeated inside `DCIM/` is copied once.

## Library Organization

Files are copied to `Year/Month/YYYYmmdd-HHMMSS-<checksum>.ext`:
- Timestamp: first valid `CreationDate`, `DateTimeOriginal`, `CreateDate` or
  `XMP-photoshop:DateCreated` (the last only when it includes a full time)
  (via `exiftool`); if none, the latest timestamp seen so far
- Live Photo videos take the timestamp of their paired still
- Checksum: first 8 hex chars of the file's SHA-1
- Extension: original, lowercased

Supported: heic heif jpg jpeg dng png gif tif tiff webp mov mp4 m4v.
Duplicates (same full SHA-1) are not copied again, so re-running is safe.
Other files, symlinks, nested subdirectories and loose files in `DCIM/`
are skipped with a warning.

Unrelated files may live under the library root; only `Year/Month` files
matching the canonical name are treated as library members.

## Requirements

- `exiftool`

## How to use

1. Mount your phone, e.g., using `ifuse /mnt/iphone/`
2. Locate `DCIM` in the mounted directory
3. `iphone2lib DCIM_dir lib_dir >i2l.log 2>i2l.err`
4. Track the status with `tail -f i2l.log`
5. Check warnings in `i2l.err`
