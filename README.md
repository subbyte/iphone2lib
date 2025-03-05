# Import iphone Photo/Video to a File-System-Based Library

- Import all data in iphone `DCIM` directory to a library.

## Library Organization

Files are renamed to `timestamp-checksum.ext`
- Timestamp is `+%Y%m%d-%H%M%S`
- Checksum is the first 8 chars of sha1sum of the file
- Extension is the original file extension in lower case

Library structure:
```
- Root
    - Year
        - Month
            - File
```

## How to use

1. Use `ifuse` to mount your phone
2. Local the `DCIM` directory
3. `iphone2lib DCIM_dir lib_dir >i2l.log 2>i2l.err`
4. Track the status with `tail -f i2l.log`
5. Check error in `i2l.err`
