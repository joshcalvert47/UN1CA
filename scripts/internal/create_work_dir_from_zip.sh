#!/usr/bin/env bash
# Copyright (c) 2026 Salvo Giangreco
# SPDX-License-Identifier: GPL-3.0-or-later

# [
source "$SRC_DIR/scripts/utils/build_utils.sh" || exit 1

ZIP_FILE="$1"
INPUT_DIR="$TMP_DIR/input_rom_zip"
MOUNT_DIR="$TMP_DIR/input_rom_mount"

trap '[ -d "$MOUNT_DIR" ] && sudo umount "$MOUNT_DIR" &> /dev/null || true; rm -rf "$INPUT_DIR" "$MOUNT_DIR" "$TMP_DIR/input_rom_partitions"' EXIT INT
PARTITIONS="system vendor product system_ext odm vendor_dlkm odm_dlkm system_dlkm"
KERNEL_BINS="boot.img dt.img dtbo.img init_boot.img vendor_boot.img recovery.img"

GET_IMAGE_FILE_SYSTEM()
{
    if [[ "$(READ_BYTES_AT "$1" "1080" "2")" == "ef53" ]]; then
        echo "ext4"
    elif [[ "$(READ_BYTES_AT "$1" "1024" "4")" == "f2f52010" ]]; then
        echo "f2fs"
    elif [[ "$(READ_BYTES_AT "$1" "1024" "4")" == "e0f5e1e2" ]]; then
        echo "erofs"
    fi
}

EXTRACT_PARTITION()
{
    local PARTITION="$1"
    local IMAGE="$2"
    local PARTITION_DIR="$TMP_DIR/input_rom_partitions/$PARTITION"
    local FILE_CONTEXT="$WORK_DIR/configs/file_context-$PARTITION"
    local FS_CONFIG="$WORK_DIR/configs/fs_config-$PARTITION"
    local FILE_SYSTEM

    FILE_SYSTEM="$(GET_IMAGE_FILE_SYSTEM "$IMAGE")"
    if [ ! "$FILE_SYSTEM" ]; then
        LOGE "Unable to determine filesystem for $PARTITION.img"
        exit 1
    fi

    LOG "- Unpacking $PARTITION.img ($FILE_SYSTEM)..."
    mkdir -p "$PARTITION_DIR" "$MOUNT_DIR"
    sudo umount "$MOUNT_DIR" &> /dev/null || true
    if [[ "$FILE_SYSTEM" == "erofs" ]]; then
        EVAL "sudo env \"PATH=$PATH\" fuse.erofs \"$IMAGE\" \"$MOUNT_DIR\"" || exit 1
    else
        EVAL "sudo mount -o ro \"$IMAGE\" \"$MOUNT_DIR\"" || exit 1
    fi

    EVAL "sudo cp -a -T \"$MOUNT_DIR\" \"$PARTITION_DIR\"" || exit 1
    sudo chown -hR "$(whoami):$(whoami)" "$PARTITION_DIR"

    LOG "- Generating metadata for $PARTITION..."
    EVAL "sudo find \"$MOUNT_DIR\" | sudo xargs -I \"{}\" -P \"$(nproc)\" stat -c \"%n %u %g %a capabilities=0x0\" \"{}\" > \"$FS_CONFIG\"" || exit 1
    EVAL "sudo find \"$MOUNT_DIR\" | sudo xargs -I \"{}\" -P \"$(nproc)\" sh -c 'echo \"\$1 \$(getfattr -n security.selinux --only-values -h --absolute-names \"\$1\")\"' \"sh\" \"{}\" > \"$FILE_CONTEXT\"" || exit 1
    sort -o "$FS_CONFIG" "$FS_CONFIG"
    sort -o "$FILE_CONTEXT" "$FILE_CONTEXT"

    if [[ "$PARTITION" == "system" ]] && [ -d "$PARTITION_DIR/system" ]; then
        sed -i -e "s|$MOUNT_DIR |/ |g" -e "s|$MOUNT_DIR||g" "$FILE_CONTEXT"
        sed -i -e "s|$MOUNT_DIR | |g" -e "s|$MOUNT_DIR/||g" "$FS_CONFIG"
    else
        sed -i "s|$MOUNT_DIR|/$PARTITION|g" "$FILE_CONTEXT"
        sed -i -e "s|$MOUNT_DIR | |g" -e "s|$MOUNT_DIR|$PARTITION|g" "$FS_CONFIG"
    fi
    sed -i -e "s|\.|\\\.|g" -e "s|\+|\\\+|g" -e "s|\[|\\\[|g" \
        -e "s|\]|\\\]|g" -e "s|\*|\\\*|g" "$FILE_CONTEXT"

    EVAL "sudo umount \"$MOUNT_DIR\"" || exit 1
    rm -f "$IMAGE"
}

if [ "$#" != "1" ] || [ ! -f "$ZIP_FILE" ]; then
    echo "Usage: create_work_dir_from_zip <flashable zip>" >&2
    exit 1
fi
if ! unzip -tq "$ZIP_FILE" >/dev/null 2>&1; then
    LOGE "File is not a valid ZIP archive: ${ZIP_FILE//$SRC_DIR\//}"
    exit 1
fi

if ! unzip -l "$ZIP_FILE" | grep -q '\.new\.dat\.br'; then
    LOGE "File does not contain any .new.dat.br OS partition payloads: ${ZIP_FILE//$SRC_DIR\//}"
    exit 1
fi
if ! sudo -n -v &> /dev/null; then
    LOG "\033[0;33m! Asking user for sudo password\033[0m"
    sudo -v || exit 1
fi

[ -d "$INPUT_DIR" ] && rm -rf "$INPUT_DIR"
[ -d "$MOUNT_DIR" ] && rm -rf "$MOUNT_DIR"
[ -d "$TMP_DIR/input_rom_partitions" ] && rm -rf "$TMP_DIR/input_rom_partitions"
[ -d "$FW_DIR" ] && rm -rf "$FW_DIR"
[ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
mkdir -p "$INPUT_DIR" "$MOUNT_DIR" "$TMP_DIR/input_rom_partitions" "$WORK_DIR/configs"

LOG "- Extracting input ROM ZIP"
EVAL "unzip -q -o \"$ZIP_FILE\" -d \"$INPUT_DIR\"" || exit 1

while IFS= read -r COMPRESSED; do
    NAME="$(basename "$COMPRESSED")"
    PARTITION="${NAME%.new.dat.br}"
    IS_VALID_PARTITION_NAME "$PARTITION" || continue

    TRANSFER_LIST="$(find "$(dirname "$COMPRESSED")" -maxdepth 1 -type f -name "$PARTITION.transfer.list" -print -quit)"
    if [ ! "$TRANSFER_LIST" ]; then
        LOGE "Missing transfer list for $NAME"
        exit 1
    fi

    LOG "- Decompressing $NAME"
    DATA_FILE="$TMP_DIR/input_rom_partitions/$PARTITION.new.dat"
    IMAGE_FILE="$TMP_DIR/input_rom_partitions/$PARTITION.img"
    EVAL "brotli --decompress --output=\"$DATA_FILE\" \"$COMPRESSED\"" || exit 1
    EVAL "python3 \"$SRC_DIR/scripts/internal/sdat2img.py\" \"$TRANSFER_LIST\" \"$DATA_FILE\" \"$IMAGE_FILE\"" || exit 1
    EXTRACT_PARTITION "$PARTITION" "$IMAGE_FILE"
done < <(find "$INPUT_DIR" -type f -name "*.new.dat.br" | LC_ALL=C sort)

for f in $PARTITIONS; do
    [ -d "$TMP_DIR/input_rom_partitions/$f" ] || continue

    if [[ "$f" == "system_ext" ]] && ! $TARGET_OS_BUILD_SYSTEM_EXT_PARTITION; then
        LOG "- Merging /system_ext into /system"
        mkdir -p "$WORK_DIR/system/system"
        EVAL "cp -a -T \"$TMP_DIR/input_rom_partitions/system_ext\" \"$WORK_DIR/system/system/system_ext\"" || exit 1
        EVAL "ln -sf \"/system/system_ext\" \"$WORK_DIR/system_ext\"" || exit 1
        SET_METADATA "system" "system_ext" 0 0 755 "u:object_r:system_file:s0"
        sed "s/^\/system_ext/\/system\/system_ext/g" "$WORK_DIR/configs/file_context-system_ext" >> "$WORK_DIR/configs/file_context-system"
        sed "s/^system_ext/system\/system_ext/g" "$WORK_DIR/configs/fs_config-system_ext" >> "$WORK_DIR/configs/fs_config-system"
        rm -rf "$TMP_DIR/input_rom_partitions/system_ext" "$WORK_DIR/configs/file_context-system_ext" "$WORK_DIR/configs/fs_config-system_ext"
    else
        EVAL "cp -a -T \"$TMP_DIR/input_rom_partitions/$f\" \"$WORK_DIR/$f\"" || exit 1
    fi
done

for f in $KERNEL_BINS; do
    KERNEL_FILE="$(find "$INPUT_DIR" -maxdepth 2 -type f -name "$f" -print -quit)"
    [ "$KERNEL_FILE" ] || continue
    mkdir -p "$WORK_DIR/kernel"
    EVAL "cp -a \"$KERNEL_FILE\" \"$WORK_DIR/kernel/$f\"" || exit 1
done

# Firmware-dependent UN1CA conditionals can inspect the supplied ROM without
# making the original archive a donor source for ADD_TO_WORK_DIR.
SOURCE_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$SOURCE_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$SOURCE_FIRMWARE")"
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
for FIRMWARE_PATH in "$SOURCE_FIRMWARE_PATH" "$TARGET_FIRMWARE_PATH"; do
    mkdir -p "$FW_DIR/$FIRMWARE_PATH"
    for f in $PARTITIONS; do
        [ -d "$WORK_DIR/$f" ] || continue
        ln -sfn "$WORK_DIR/$f" "$FW_DIR/$FIRMWARE_PATH/$f"
    done
done

exit 0
