#!/bin/bash
#
# verify-clone.sh
#
# Sanity-checks a card cloned with rpi-clone before you trust it to boot.
# Confirms cmdline.txt, fstab, and the actual partition PARTUUIDs all agree,
# and that the root filesystem looks populated.
#
# Usage:
#   sudo ./verify-clone.sh sdb
#
# (pass the bare device name of the CLONED card - e.g. sdb, not sdb1/sdb2)

set -u

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo ./verify-clone.sh <device>)"
    exit 1
fi

if [ $# -ne 1 ]; then
    echo "Usage: sudo $0 <device>   (e.g. sudo $0 sdb)"
    exit 1
fi

DEV="$1"
BOOT_PART="/dev/${DEV}1"
ROOT_PART="/dev/${DEV}2"
BOOT_MNT="/mnt/verify-boot"
ROOT_MNT="/mnt/verify-root"

PASS=0
FAIL=0

check() {
    if [ "$1" = "ok" ]; then
        echo "  [PASS] $2"
        PASS=$((PASS+1))
    else
        echo "  [FAIL] $2"
        FAIL=$((FAIL+1))
    fi
}

cleanup() {
    umount "$BOOT_MNT" 2>/dev/null
    umount "$ROOT_MNT" 2>/dev/null
}
trap cleanup EXIT

echo "=== Checking partitions on /dev/$DEV ==="
lsblk "/dev/$DEV"
echo ""

if [ ! -b "$BOOT_PART" ] || [ ! -b "$ROOT_PART" ]; then
    echo "Could not find $BOOT_PART and $ROOT_PART - aborting."
    exit 1
fi

mkdir -p "$BOOT_MNT" "$ROOT_MNT"

echo "=== Mounting partitions ==="
mount "$BOOT_PART" "$BOOT_MNT" || { echo "Failed to mount $BOOT_PART"; exit 1; }
mount "$ROOT_PART" "$ROOT_MNT" || { echo "Failed to mount $ROOT_PART"; exit 1; }
echo ""

# Get the real PARTUUID of the root partition directly from the card
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART")
echo "=== Actual root PARTUUID (from blkid): $ROOT_PARTUUID ==="
echo ""

echo "=== Checking cmdline.txt ==="
CMDLINE_PARTUUID=$(grep -oP 'root=PARTUUID=\K[0-9a-fA-F-]+' "$BOOT_MNT/cmdline.txt")
echo "  cmdline.txt root=PARTUUID=$CMDLINE_PARTUUID"
if [ "$CMDLINE_PARTUUID" = "${ROOT_PARTUUID}" ]; then
    check ok "cmdline.txt PARTUUID matches actual root partition"
else
    check fail "cmdline.txt PARTUUID ($CMDLINE_PARTUUID) does NOT match root partition ($ROOT_PARTUUID)"
fi
echo ""

echo "=== Checking fstab ==="
cat "$ROOT_MNT/etc/fstab"
if grep -q "PARTUUID=${ROOT_PARTUUID}" "$ROOT_MNT/etc/fstab"; then
    check ok "fstab references the correct root PARTUUID"
else
    check fail "fstab does NOT reference the correct root PARTUUID ($ROOT_PARTUUID)"
fi
echo ""

echo "=== Checking root filesystem looks complete ==="
EXPECTED_DIRS="bin etc home usr var"
MISSING=""
for d in $EXPECTED_DIRS; do
    if [ ! -d "$ROOT_MNT/$d" ]; then
        MISSING="$MISSING $d"
    fi
done
if [ -z "$MISSING" ]; then
    check ok "root filesystem contains expected top-level directories"
else
    check fail "root filesystem is missing:$MISSING"
fi
echo ""

echo "=== Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo "All checks passed. Safe to shut down and boot from this card."
    exit 0
else
    echo "One or more checks failed - do NOT boot from this card yet."
    exit 1
fi
