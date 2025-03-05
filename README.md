# Import iphone Photo/Video to Library

Import all data in iphone `DCIM` directory to a file-system-based library.

## Library Organization

Files are renamed to `timestamp-checksum.ext`
- Timestamp is extracted with `exiftool`
- If no timestamp found, use latest timestamp from previous files
- Timestamp format: `+%Y%m%d-%H%M%S`
- Checksum is the first 8 chars of sha1sum of the file
- Extension is the original file extension in lower case

Library structure:
```
- Root
    - Year
        - Month
            - File
```

## Requirements

- `exiftool`

## How to use

1. Mount your phone, e.g., using `ifuse`
2. Locate `DCIM` in the mounted directory
3. `iphone2lib DCIM_dir lib_dir >i2l.log 2>i2l.err`
4. Track the status with `tail -f i2l.log`
5. Check error in `i2l.err`
