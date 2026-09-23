#!/usr/bin/bash
#
# checkfile.sh - find photo/video files whose names were mis-timestamped by the
# old iphone2lib, and print the current name alongside the corrected name.
#
# Two distinct old-script bugs produced wrong names:
#   * Videos (#1): the old script read the QuickTime "CreateDate", which is
#     UTC, and interpreted it in the machine's local TZ, mis-bucketing videos
#     by the UTC offset (wrong H/M/S and possibly wrong Year/Month folder).
#   * Photos (#2/#3): the old script grepped for the first tag containing both
#     "Date" and "Create", an arbitrary choice. Where DateTimeOriginal (capture
#     time) and CreateDate (e.g. re-encode time of an edited/app-saved image)
#     differ, it could record the wrong one.
#
# The fix for BOTH is one tag priority, matching the fixed iphone2lib:
#     CreationDate -> DateTimeOriginal -> CreateDate   (normalized to local
#     wall-clock). CreationDate carries the camera offset for video and is
#     simply absent on photos, so the same priority is correct for each.
#
# This tool recomputes the correct timestamp with that priority and compares it
# against the timestamp encoded in the current filename. Only the timestamp and
# Year/Month can be wrong: file content is untouched, so the checksum and
# extension in the name still hold.
#
# It CHANGES NOTHING. For each mismatch it prints, tab-separated:
#     <current path> <TAB> <corrected path>
# so you can review before acting. Diagnostics go to stderr.
#
# Usage: checkfile.sh lib_dir [--photos-only | --videos-only]
#   lib_dir is the destination library root (contains Year/Month/ subdirs).

if [ ! -x "$(command -v exiftool)" ]; then
    echo "Requirement unmet: exiftool" >&2
    exit 1
fi

mode="all"
apply=0        # 0 = report only (default), 1 = actually mv files
lib_dir=""
for arg in "$@"; do
    case "$arg" in
        --photos-only) mode="photos" ;;
        --videos-only) mode="videos" ;;
        --apply) apply=1 ;;
        -*) echo "Unknown option: $arg" >&2; exit 1 ;;
        *) lib_dir=$arg ;;
    esac
done

if [ -z "$lib_dir" ] || [ ! -d "$lib_dir" ]; then
    echo "Usage: $0 lib_dir [--photos-only | --videos-only] [--apply]" >&2
    echo "  lib_dir should contain Year/Month/ subdirs (see iphone2lib)" >&2
    echo "  without --apply: report mismatches only (dry run, changes nothing)" >&2
    echo "  with --apply:    move each mismatched file to its corrected path," >&2
    echo "                   creating the Year/Month folder if needed" >&2
    exit 1
fi

# Classify by lower-cased extension (iphone2lib lower-cases extensions).
# Returns: prints "video" or "photo" on stdout, or nothing if not media.
# Add extensions here if your library contains others.
classify_ext() {
    case "$1" in
        mov|mp4|m4v|avi|3gp|3g2)             echo "video" ;;
        heic|heif|jpg|jpeg|png|gif|tiff|tif|dng|webp) echo "photo" ;;
        *) : ;;
    esac
}

# handle spaces in paths
IFS='
'

nphoto=0
nvideo=0
nmismatch=0
nnotime=0
nmoved=0
nconflict=0
nmvfail=0

# Library names are timestamp-checksum.ext (no newlines by construction), so a
# plain find + IFS=newline read is fine and keeps the loop in the current shell
# for the counters.
for f in $(find "$lib_dir" -type f)
do
    fname=$(basename "$f")
    ext=$(echo "${fname##*.}" | tr '[:upper:]' '[:lower:]')
    kind=$(classify_ext "$ext")
    [ -n "$kind" ] || continue

    # honor mode filter
    if [ "$mode" = "photos" ] && [ "$kind" != "photo" ]; then continue; fi
    if [ "$mode" = "videos" ] && [ "$kind" != "video" ]; then continue; fi

    # Current filename encodes the OLD timestamp as YYYYMMDD-HHMMSS-<8hex>.ext.
    # Pull the YYYYMMDD-HHMMSS prefix; skip anything not matching the pattern.
    old_stamp=$(echo "$fname" | grep -oE '^[0-9]{8}-[0-9]{6}')
    if [ -z "$old_stamp" ]; then
        echo "SKIP (unrecognized name): $f" >&2
        continue
    fi

    if [ "$kind" = "photo" ]; then
        nphoto=$((nphoto + 1))
    else
        nvideo=$((nvideo + 1))
    fi

    # Recompute the CORRECT timestamp with the fixed tag priority.
    currTS=$(exiftool -s3 -d '%Y-%m-%d %H:%M:%S' \
        -CreationDate -DateTimeOriginal -CreateDate "$f" \
        | head -n 1)

    if [ -z "$currTS" ] || ! date -d "$currTS" >/dev/null 2>&1; then
        # No usable timestamp. The old script would have used its baseTS
        # fallback here, which this tool cannot reconstruct, so the correct
        # name cannot be asserted. Report for manual review.
        echo "NOTIME ($kind, no usable timestamp, review manually): $f" >&2
        nnotime=$((nnotime + 1))
        continue
    fi

    # Preserve the original checksum + extension from the current name; only the
    # time portion is being corrected.
    csext=${fname#${old_stamp}-}          # strip "YYYYMMDD-HHMMSS-"
    new_stamp=$(date -d "$currTS" +%Y%m%d-%H%M%S)
    year=$(date -d "$currTS" +%Y)
    month=$(date -d "$currTS" +%m)
    new_path="$lib_dir/$year/$month/$new_stamp-$csext"

    if [ "$f" != "$new_path" ]; then
        nmismatch=$((nmismatch + 1))
        # tab-separated: current path <TAB> corrected path
        printf '%s\t%s\n' "$f" "$new_path"

        if [ "$apply" -eq 1 ]; then
            if [ -e "$new_path" ]; then
                # Refuse to clobber. The target may be a legitimately-timed
                # duplicate already in place, or two files may correct to the
                # same name. Either way, do not lose data - report and skip.
                echo "CONFLICT (target exists, not moved): $f -> $new_path" >&2
                nconflict=$((nconflict + 1))
            else
                mkdir -p "$lib_dir/$year/$month"
                if mv -n "$f" "$new_path"; then
                    nmoved=$((nmoved + 1))
                else
                    echo "MVFAIL (mv failed, left in place): $f -> $new_path" >&2
                    nmvfail=$((nmvfail + 1))
                fi
            fi
        fi
    fi
done

echo "" >&2
echo "checked photos : $nphoto" >&2
echo "checked videos : $nvideo" >&2
echo "mismatches     : $nmismatch" >&2
echo "no-timestamp   : $nnotime (reported above, need manual review)" >&2
if [ "$apply" -eq 1 ]; then
    echo "moved          : $nmoved" >&2
    echo "conflicts      : $nconflict (target existed, left in place)" >&2
    echo "mv failures    : $nmvfail (reported above)" >&2
else
    echo "(dry run - no files changed; pass --apply to perform the moves)" >&2
fi
