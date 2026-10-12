#!/usr/bin/bash
#
# checkfile.sh - find photo/video files whose names were mis-timestamped by the
# old iphone2lib, print the current name alongside the corrected name, and
# optionally perform the rename.
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
# Three extra concerns this tool handles:
#   * NO-TIMESTAMP FILES: the old iphone2lib gave a file with no usable EXIF the
#     timestamp of the most recent file that DID have one ("baseTS"). Such a
#     file therefore shares that predecessor's YYYYMMDD-HHMMSS prefix. If the
#     predecessor is now corrected, the inheritor must FOLLOW it to the same new
#     timestamp (keeping its own checksum+ext), or its name points at a stale
#     time. We cannot recompute an inheritor's time from metadata (it has none),
#     so we group files by their current prefix: a file matching its own EXIF is
#     an ANCHOR; a file with no EXIF sharing that prefix is an INHERITOR and
#     follows the anchor's correction. Zero/ambiguous anchors -> report, no move.
#   * LIVE PHOTOS: an Apple Live Photo is a still + a .mov sharing a Content
#     Identifier UUID. They have independent timestamps and so could land in
#     different folders. We pair them by UUID and make the video FOLLOW the
#     still's corrected timestamp, so the pair keeps one prefix / one folder.
#   * SUPPRESSION: files already correctly named are not printed (use --verbose
#     to list them as OK).
#
# Only the timestamp and Year/Month in a name can be wrong: content is
# untouched, so the checksum and extension in the name still hold.
#
# Without --apply it CHANGES NOTHING. For each file needing a rename it prints,
# tab-separated:  <current path> <TAB> <corrected path>  on stdout. All
# diagnostics and the summary go to stderr.
#
# Usage: checkfile.sh lib_dir [--photos-only | --videos-only] [--apply] [--verbose]
#   lib_dir is the destination library root (contains Year/Month/ subdirs).

if [ ! -x "$(command -v exiftool)" ]; then
    echo "Requirement unmet: exiftool" >&2
    exit 1
fi

mode="all"
apply=0        # 0 = report only (default), 1 = actually mv files
verbose=0      # 1 = also print files that need no rename (OK lines)
lib_dir=""
for arg in "$@"; do
    case "$arg" in
        --photos-only) mode="photos" ;;
        --videos-only) mode="videos" ;;
        --apply) apply=1 ;;
        --verbose) verbose=1 ;;
        -*) echo "Unknown option: $arg" >&2; exit 1 ;;
        *) lib_dir=$arg ;;
    esac
done

if [ -z "$lib_dir" ] || [ ! -d "$lib_dir" ]; then
    echo "Usage: $0 lib_dir [--photos-only | --videos-only] [--apply] [--verbose]" >&2
    echo "  lib_dir should contain Year/Month/ subdirs (see iphone2lib)" >&2
    echo "  without --apply: report renames only (dry run, changes nothing)" >&2
    echo "  with --apply:    move each file to its corrected path, creating the" >&2
    echo "                   Year/Month folder if needed, never clobbering" >&2
    echo "  --verbose:       also print files that are already correct (OK)" >&2
    exit 1
fi

# Classify by lower-cased extension (iphone2lib lower-cases extensions).
# Prints "video" or "photo", or nothing if not media. Extend as needed.
classify_ext() {
    case "$1" in
        mov|mp4|m4v|avi|3gp|3g2)                      echo "video" ;;
        heic|heif|jpg|jpeg|png|gif|tiff|tif|dng|webp) echo "photo" ;;
        *) : ;;
    esac
}

# Compute the corrected local-wall-clock timestamp for a file using the fixed
# tag priority. Prints "YYYY-MM-DD HH:MM:SS" or nothing if no usable date.
probe_ts() {
    local ts
    ts=$(exiftool -s3 -d '%Y-%m-%d %H:%M:%S' \
        -CreationDate -DateTimeOriginal -CreateDate "$1" 2>/dev/null | head -n 1)
    if [ -n "$ts" ] && date -d "$ts" >/dev/null 2>&1; then
        echo "$ts"
    fi
}

# handle spaces in paths
IFS='
'

# ---- Per-file arrays (indexed by a running integer id) ----
declare -a F_PATH F_PREFIX F_CSEXT F_KIND F_TS F_UUID
# ---- Maps built after pass 1 ----
# anchor correction target per file id (new "YYYYMMDD-HHMMSS" prefix)
declare -a F_NEWSTAMP
# prefix -> space-separated list of anchor ids that carry that OLD prefix
declare -A PREFIX_ANCHORS
# normalized uuid -> still anchor id (for Live Photo pairing)
declare -A UUID_STILL

n=0
nphoto=0
nvideo=0

# ============================ PASS 1: probe ============================
for f in $(find "$lib_dir" -type f)
do
    fname=$(basename "$f")
    ext=$(echo "${fname##*.}" | tr '[:upper:]' '[:lower:]')
    kind=$(classify_ext "$ext")
    [ -n "$kind" ] || continue

    if [ "$mode" = "photos" ] && [ "$kind" != "photo" ]; then continue; fi
    if [ "$mode" = "videos" ] && [ "$kind" != "video" ]; then continue; fi

    # Current name encodes the OLD timestamp as YYYYMMDD-HHMMSS-<8hex>.ext.
    old_stamp=$(echo "$fname" | grep -oE '^[0-9]{8}-[0-9]{6}')
    if [ -z "$old_stamp" ]; then
        echo "SKIP (unrecognized name): $f" >&2
        continue
    fi

    ts=$(probe_ts "$f")                     # empty => inheritor (no own EXIF)
    uuid=$(exiftool -s3 -ContentIdentifier "$f" 2>/dev/null \
           | head -n 1 | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

    F_PATH[$n]=$f
    F_PREFIX[$n]=$old_stamp
    F_CSEXT[$n]=${fname#${old_stamp}-}      # "<8hex>.ext"
    F_KIND[$n]=$kind
    F_TS[$n]=$ts
    F_UUID[$n]=$uuid
    F_NEWSTAMP[$n]=""

    if [ "$kind" = "photo" ]; then nphoto=$((nphoto + 1)); else nvideo=$((nvideo + 1)); fi

    if [ -n "$ts" ]; then
        # anchor: has its own usable timestamp
        new_stamp=$(date -d "$ts" +%Y%m%d-%H%M%S)
        F_NEWSTAMP[$n]=$new_stamp
        # newline-separated so it splits correctly under IFS=newline
        PREFIX_ANCHORS[$old_stamp]="${PREFIX_ANCHORS[$old_stamp]}${n}
"
        # record the STILL side of a Live Photo for pairing
        if [ -n "$uuid" ] && [ "$kind" = "photo" ]; then
            UUID_STILL[$uuid]=$n
        fi
    fi
    n=$((n + 1))
done

# =================== PASS 2: resolve targets & act ===================
nrename=0
nok=0
nnotime=0
nambig=0
nmoved=0
nconflict=0
nmvfail=0

emit() {
    # $1 current path, $2 corrected path, $3 reason-tag for stderr
    printf '%s\t%s\n' "$1" "$2"
}

do_move() {
    # $1 current path, $2 corrected path, $3 "YYYY/MM" dest subdir
    if [ -e "$2" ]; then
        echo "CONFLICT (target exists, not moved): $1 -> $2" >&2
        nconflict=$((nconflict + 1))
        return
    fi
    mkdir -p "$lib_dir/$3"
    if mv -n "$1" "$2"; then
        nmoved=$((nmoved + 1))
    else
        echo "MVFAIL (mv failed, left in place): $1 -> $2" >&2
        nmvfail=$((nmvfail + 1))
    fi
}

i=0
while [ "$i" -lt "$n" ]; do
    f=${F_PATH[$i]}
    prefix=${F_PREFIX[$i]}
    csext=${F_CSEXT[$i]}
    kind=${F_KIND[$i]}
    ts=${F_TS[$i]}
    uuid=${F_UUID[$i]}
    new_stamp=${F_NEWSTAMP[$i]}

    if [ -z "$ts" ]; then
        # ---- INHERITOR: no own EXIF; follow its prefix group's anchor ----
        # PREFIX_ANCHORS[prefix] is a newline-separated list of anchor ids that
        # carry this OLD prefix. Collect the distinct corrected stamps among
        # them; IFS=newline makes the for-loop split correctly.
        anchors=${PREFIX_ANCHORS[$prefix]}
        distinct=""
        ndistinct=0
        for a in $anchors; do
            [ -n "$a" ] || continue
            s=${F_NEWSTAMP[$a]}
            case "${distinct}" in
                *"${s}"$'\n'*) : ;;                 # already seen
                *) distinct="${distinct}${s}"$'\n'; ndistinct=$((ndistinct + 1)) ;;
            esac
        done
        if [ "$ndistinct" -eq 0 ]; then
            echo "NOTIME ($kind, no own timestamp and no anchor to follow): $f" >&2
            nnotime=$((nnotime + 1))
            i=$((i + 1)); continue
        elif [ "$ndistinct" -gt 1 ]; then
            echo "AMBIG ($kind, prefix $prefix inherited from >1 corrected time): $f" >&2
            nambig=$((nambig + 1))
            i=$((i + 1)); continue
        fi
        new_stamp=${distinct%$'\n'}                  # the single stamp
    elif [ -n "$uuid" ] && [ "$kind" = "video" ] && [ -n "${UUID_STILL[$uuid]}" ]; then
        # ---- LIVE PHOTO video: follow the paired still's corrected stamp ----
        still=${UUID_STILL[$uuid]}
        new_stamp=${F_NEWSTAMP[$still]}
    fi

    # build corrected path from new_stamp (YYYYMMDD-HHMMSS) + original csext
    y=${new_stamp:0:4}
    mo=${new_stamp:4:2}
    new_path="$lib_dir/$y/$mo/$new_stamp-$csext"

    if [ "$f" = "$new_path" ]; then
        # ---- already correct: suppress unless --verbose ----
        nok=$((nok + 1))
        [ "$verbose" -eq 1 ] && echo "OK: $f" >&2
        i=$((i + 1)); continue
    fi

    nrename=$((nrename + 1))
    emit "$f" "$new_path"
    [ "$apply" -eq 1 ] && do_move "$f" "$new_path" "$y/$mo"
    i=$((i + 1))
done

echo "" >&2
echo "checked photos : $nphoto" >&2
echo "checked videos : $nvideo" >&2
echo "need rename    : $nrename" >&2
echo "already OK     : $nok (suppressed; use --verbose to list)" >&2
echo "no-timestamp   : $nnotime (no anchor to follow, review manually)" >&2
echo "ambiguous      : $nambig (inherited prefix maps to >1 time, review)" >&2
if [ "$apply" -eq 1 ]; then
    echo "moved          : $nmoved" >&2
    echo "conflicts      : $nconflict (target existed, left in place)" >&2
    echo "mv failures    : $nmvfail (reported above)" >&2
else
    echo "(dry run - no files changed; pass --apply to perform the moves)" >&2
fi
