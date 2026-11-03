#!/usr/bin/env bash
# Verify mkmaciso end to end.
#
# Layers 1-3 (table, parsing, Apple URLs) run anywhere. The layer that actually
# needs Apple's tooling - fetching an installer and producing a bootable image -
# only runs on macOS, and only when --build is given.
#
#   ./tools/verify-on-macos.sh                        # checks + resolve one release
#   ./tools/verify-on-macos.sh --version 10.15        # same, for a specific release
#   ./tools/verify-on-macos.sh --version 10.15 --build   # really build the image
#   ./tools/verify-on-macos.sh --build --vm --osx-kvm ~/OSX-KVM   # also emit a QEMU boot script
#
# Nothing here downloads gigabytes unless --build is passed. A report is written
# next to the artifacts so the result can be attached to an issue.
#
# Exit status: 0 when nothing failed, 1 when a check failed.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MKMACISO="$ROOT/mkmaciso"
TABLE="${MKMACISO_DATA:-$ROOT/versions.tsv}"

VERSION=""
DO_BUILD=0
DO_VM=0
SKIP_NET=0
OSX_KVM="${OSX_KVM:-}"
OUT_ROOT=""

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version|-v) VERSION="${2:-}"; shift 2 ;;
        --build) DO_BUILD=1; shift ;;
        --vm) DO_VM=1; shift ;;
        --skip-network) SKIP_NET=1; shift ;;
        --osx-kvm) OSX_KVM="${2:-}"; shift 2 ;;
        --out) OUT_ROOT="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [ -z "$OUT_ROOT" ]; then
    OUT_ROOT="${TMPDIR:-/tmp}/mkmaciso-verify"
fi
mkdir -p "$OUT_ROOT" || exit 2
REPORT="$OUT_ROOT/verify-report.txt"
: > "$REPORT"

pass=0
fail=0
skipped=0

say() {
    printf '%s\n' "$*"
    printf '%s\n' "$*" >> "$REPORT"
}

ok()   { say "  ok      $*"; pass=$((pass + 1)); }
bad()  { say "  FAIL    $*"; fail=$((fail + 1)); }
note() { say "  skip    $*"; skipped=$((skipped + 1)); }

# Run a command, show its output, keep it in the report, return its status.
run_logged() {
    "$@" 2>&1 | tee -a "$REPORT"
    return "${PIPESTATUS[0]}"
}

say "mkmaciso verification"
say "date      $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say "host      $(uname -s) $(uname -r) $(uname -m)"
say "root      $ROOT"
say "report    $REPORT"

darwin=0
if [ "$(uname -s)" = "Darwin" ]; then
    darwin=1
fi

# --------------------------------------------------------------- 1. presence
say ""
say "== files"
for f in "$MKMACISO" "$TABLE" "$ROOT/tools/check-versions.sh"; do
    if [ -f "$f" ]; then ok "$(basename "$f") present"; else bad "$(basename "$f") missing"; fi
done
if [ ! -x "$MKMACISO" ]; then
    bad "mkmaciso is not executable (chmod +x mkmaciso)"
fi
if [ ! -x "$ROOT/tools/check-versions.sh" ]; then
    bad "tools/check-versions.sh is not executable"
fi

# --------------------------------------------------------------- 2. syntax
say ""
say "== syntax"
for f in "$MKMACISO" "$ROOT/tools/check-versions.sh" "$ROOT/tools/probe-urls.sh" "$ROOT/tools/verify-on-macos.sh"; do
    if [ -f "$f" ]; then
        if run_logged bash -n "$f"; then
            ok "bash -n $(basename "$f")"
        else
            bad "bash -n $(basename "$f")"
        fi
    fi
done

# --------------------------------------------------------------- 3. table
say ""
say "== version table"
if run_logged "$ROOT/tools/check-versions.sh"; then
    ok "check-versions.sh"
else
    bad "check-versions.sh"
fi

listing=$("$MKMACISO" --list 2>&1)
if printf '%s' "$listing" | grep -q 'Tahoe'; then
    ok "mkmaciso --list reports the table"
else
    bad "mkmaciso --list did not report the table"
    printf '%s\n' "$listing" | tee -a "$REPORT"
fi

# --------------------------------------------------------------- 4. resolve
say ""
say "== resolve"
if [ -z "$VERSION" ]; then
    VERSION=$(awk -F'\t' '!/^#/ && NF == 10 { v = $3 } END { print v }' "$TABLE")
    say "  no --version given, using the last row: $VERSION"
fi

if run_logged "$MKMACISO" "$VERSION" iso --dry-run; then
    ok "$VERSION resolves"
else
    bad "$VERSION does not resolve"
fi

# --------------------------------------------------------------- 5. network
say ""
say "== Apple URLs"
if [ "$SKIP_NET" -eq 1 ]; then
    note "network probe skipped (--skip-network)"
elif ! command -v curl >/dev/null 2>&1; then
    note "curl not available"
else
    if run_logged "$ROOT/tools/probe-urls.sh"; then
        ok "every probeable Apple URL answered"
    else
        bad "at least one Apple URL is gone; see the table above"
    fi
fi

# ---------------------------------------------------------- 6. real build
say ""
say "== build"
if [ "$darwin" -eq 0 ]; then
    note "building needs macOS: softwareupdate, hdiutil and createinstallmedia"
elif [ "$DO_BUILD" -eq 0 ]; then
    note "not requested (pass --build to download and build for real)"
else
    free_gb=$(df -g "$OUT_ROOT" 2>/dev/null | awk 'NR == 2 { print $4 }')
    say "  free space at $OUT_ROOT: ${free_gb:-?} GB"
    if [ -n "$free_gb" ] && [ "$free_gb" -lt 40 ]; then
        bad "a full installer build wants about 40 GB free, found $free_gb GB"
    else
        ok "enough free space"
    fi

    if sudo -n true 2>/dev/null; then
        ok "sudo is already cached"
    else
        say "  sudo password will be asked for (mkmaciso mounts images and writes to /Applications)"
        sudo -v || bad "sudo not granted"
    fi

    image="$OUT_ROOT/macOS_${VERSION}.iso"
    started=$(date +%s)
    if run_logged "$MKMACISO" "$VERSION" iso "$image"; then
        elapsed=$(( $(date +%s) - started ))
        ok "mkmaciso produced $image in ${elapsed}s"
    else
        bad "mkmaciso exited non-zero"
    fi

    if [ -f "$image" ]; then
        bytes=$(stat -f%z "$image" 2>/dev/null || echo 0)
        if [ "$bytes" -gt 1000000000 ]; then
            ok "artifact is $(awk -v b="$bytes" 'BEGIN { printf "%.2f GB", b / 1073741824 }')"
        else
            bad "artifact is only $bytes bytes, that is not a usable image"
        fi

        if run_logged hdiutil imageinfo "$image"; then
            ok "hdiutil imageinfo reads the artifact"
        else
            bad "hdiutil cannot read the artifact"
        fi

        mnt="$OUT_ROOT/mnt"
        mkdir -p "$mnt"
        if hdiutil attach -readonly -noverify -noautoopen -mountpoint "$mnt" "$image" >> "$REPORT" 2>&1; then
            top=$(ls "$mnt" 2>/dev/null | tr '\n' ' ')
            if printf '%s' "$top" | grep -q '\.app\|BaseSystem'; then
                ok "mounted volume contains: $top"
            else
                bad "mounted volume looks empty: $top"
            fi
            hdiutil detach "$mnt" >> "$REPORT" 2>&1 || true
        else
            bad "cannot mount the artifact"
        fi
    fi
fi

# ---------------------------------------------------------------- 7. boot
say ""
say "== boot"
if [ "$DO_VM" -eq 0 ]; then
    note "not requested (pass --vm to emit a QEMU boot script)"
elif [ -z "$OSX_KVM" ] || [ ! -d "$OSX_KVM" ]; then
    note "set --osx-kvm /path/to/OSX-KVM; the QEMU boot needs its OpenCore.qcow2 and OVMF blobs"
else
    image="$OUT_ROOT/macOS_${VERSION}.iso"
    boot="$OUT_ROOT/boot-${VERSION}-in-qemu.sh"
    for f in "$OSX_KVM/OpenCore/OpenCore.qcow2" "$OSX_KVM/OVMF_CODE_4M.fd" "$OSX_KVM/OVMF_VARS-1920x1080.fd"; do
        if [ -f "$f" ]; then ok "found $(basename "$f")"; else bad "missing $f"; fi
    done
    if [ ! -f "$image" ]; then
        note "$image does not exist yet, generating the script anyway"
    fi

    cat > "$boot" <<'QEMUEOF'
#!/usr/bin/env bash
# Boot an image produced by mkmaciso inside QEMU, so the installer can be seen
# starting up. Based on OSX-KVM's OpenCore-Boot.sh: OpenCore pretends to be Mac
# firmware, the produced image is attached as a CD, and the boot picker offers
# "macOS Base System" if the image is intact.
#
# Requires: Linux or macOS host with KVM (macOS host needs HVF instead), the
# OSX-KVM checkout for OpenCore + OVMF, and an empty disk for the install.
#
# Apple licenses macOS virtualisation on Apple-branded hardware only. Whether
# this host qualifies is your call, not something this script can check.
set -uo pipefail

OSX_KVM="__OSX_KVM__"
IMAGE="__IMAGE__"
DISK="__DISK__"

if [ ! -f "$DISK" ]; then
    printf 'creating %s (256G sparse)\n' "$DISK"
    qemu-img create -f qcow2 "$DISK" 256G
fi

if [ "$(uname -s)" = Darwin ]; then ACCEL="hvf"; else ACCEL="kvm"; fi

# Swap the CPU model if the boot hangs before OpenCore's picker appears:
#   Haswell-noTSX              macOS 11-14 on a Haswell or newer host
#   Skylake-Client,-hle,-rtm   macOS 15 and 26
#   Penryn                     macOS 10.13-10.15
exec qemu-system-x86_64 \
    -accel "$ACCEL" -m 4096 \
    -cpu Haswell-noTSX,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check \
    -machine q35 \
    -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0 \
    -smp 4,cores=2,sockets=1 \
    -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc" \
    -drive if=pflash,format=raw,readonly=on,file="$OSX_KVM/OVMF_CODE_4M.fd" \
    -drive if=pflash,format=raw,file="$OSX_KVM/OVMF_VARS-1920x1080.fd" \
    -smbios type=2 \
    -device ich9-intel-hda -device hda-duplex \
    -device ich9-ahci,id=sata \
    -drive id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file="$OSX_KVM/OpenCore/OpenCore.qcow2" \
    -device ide-hd,bus=sata.2,drive=OpenCoreBoot \
    -drive id=InstallMedia,if=none,media=cdrom,readonly=on,file="$IMAGE",format=raw \
    -device ide-cd,bus=sata.3,drive=InstallMedia \
    -drive id=MacHDD,if=none,file="$DISK",format=qcow2 \
    -device ide-hd,bus=sata.4,drive=MacHDD \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0,mac=52:54:00:c9:18:27 \
    -device vmware-svga
QEMUEOF

    sed -i.bak \
        -e "s#__OSX_KVM__#$OSX_KVM#g" \
        -e "s#__IMAGE__#$image#g" \
        -e "s#__DISK__#$OUT_ROOT/mac_hdd_ng.img#g" \
        "$boot" && rm -f "$boot.bak"
    chmod +x "$boot"
    ok "wrote $boot"
    say "  run it and watch the boot picker for 'macOS Base System'"
fi

# ---------------------------------------------------------------- summary
say ""
say "== summary"
say "  $pass ok, $fail failed, $skipped skipped"
if [ "$fail" -gt 0 ]; then
    say "  see $REPORT"
    exit 1
fi
say "  report: $REPORT"
exit 0
