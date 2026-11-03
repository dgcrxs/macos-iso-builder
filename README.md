# Overview

Build bootable macOS installer ISOs and DMGs directly from Apple's servers — no Mac required.

This is a self-use fork of [LongQT-sea/macos-iso-builder](https://github.com/LongQT-sea/macos-iso-builder). Upstream is unchanged; this fork only removes the parts that cannot work outside the original repo. See [Changes in this fork](#changes-in-this-fork).

This project has two parts:
1. A script (`mkmaciso`) that uses only macOS built-in tools and commands to download and install the full macOS installer from Apple's servers into **/Applications**, and then creates bootable ISO/DMG images.
2. GitHub Action workflows that run `mkmaciso` on Azure datacenter-hosted Mac minis if you don't have macOS.

## Before you start

This fork has no prebuilt images attached. Build what you need yourself — the Recovery workflow takes 2-5 minutes.

> [!Important]
> GitHub-hosted runners are a free public resource — please use them responsibly.

## Disk Image Formats

| | ISO | DMG |
|---|---|---|
| Best for | Virtual Machines | Bootable USB |
| VM Support | Attach as virtual DVD | Attach as virtual hard disk |
| Layout | Hybrid UDF/HFS | Raw GPT disk image |

**ISO files** - These work great for VMs *(Proxmox, QEMU, VMware)*. Just attach them like a virtual DVD. They'll even mount in Windows if you need to poke around inside.

**DMG files** - Flash these to a USB drive with [Rufus](https://rufus.ie/en/#download) *(Windows)*, `dd` *(Linux)*, or `asr` *(macOS)* to make bootable installation media. For VM use, convert them to `.vhd` *(for Hyper-V)* or `.vmdk` *(for VMware)* with `qemu-img`. QEMU/Proxmox can use the raw disk image without conversion.
> Note: DMG files ship with a `.img` suffix *(e.g. macOS_Sequoia.dmg.img)* so Rufus can find them without switching to "All files" in Explorer.

## Supported versions

Pretty much everything from OS X Lion (10.7, 2011) through the latest macOS Tahoe (26, 2025). Full list:

Lion, Mountain Lion, Mavericks, Yosemite, El Capitan, Sierra, High Sierra, Mojave, Catalina, Big Sur, Monterey, Ventura, Sonoma, Sequoia, Tahoe.

---

## How to use

### Don't have macOS? Use GitHub Actions

> [!TIP]
> <details>
> <summary>Click here to watch a visual guide (GIF)</summary>
>
> ![](./.github/how_to_fork_and_run_workflow.gif)
>
> </details>

1. Fork this repository (requires a GitHub account).
2. Navigate to the **Actions** tab in your forked repository.
3. Click the green **"I understand my workflows, go ahead and enable them"** button.
4. Select a workflow from the left sidebar:
   * **Recovery ISO** *(recommended)* - Small recovery image, builds in 2-5 minutes. Good for VMs.
   * **Full Installer** - Complete offline installer, 5-18GB, takes 5-60 minutes to build.
5. Click the **"Run workflow"** button and configure the workflow inputs:

   * **macOS version** – Choose a version (*Sequoia*, *Sonoma*, etc.).
   * **Image format** – Choose `iso` for virtual machines or `dmg` for bootable USB drives.
6. Click the green **"Run workflow"** button to start the build, then wait for the workflow to complete.
7. Once completed, reload the page and scroll down to the **Artifacts** section. Click the artifact link to start downloading (e.g., `macOS_Sequoia_15.7.4.iso`).
8. **Recovery ISO** artifacts are zipped — unzip before use.

---

### Already have macOS? Run `mkmaciso` locally

The script reads its version table from `versions.tsv`, so fetch both files:
```bash
BASE=https://raw.githubusercontent.com/<your-name>/macos-iso-builder/main
curl -O "$BASE/mkmaciso" -O "$BASE/versions.tsv"
chmod +x mkmaciso
./mkmaciso --help
./mkmaciso --list              # every supported release
./mkmaciso 26 iso --dry-run    # resolve the version, download nothing
```

Running `./mkmaciso` without arguments gives you an interactive menu.

If the table lives elsewhere, point at it with `MKMACISO_DATA`:

```bash
MKMACISO_DATA=/path/to/versions.tsv ./mkmaciso tahoe
```

The `curl … | bash` one-liner no longer works: a piped script has no directory to read `versions.tsv` from, and silently inventing versions would be worse than failing.

---

## Changes in this fork

Only the pieces that hardcoded the upstream owner, depended on upstream-only privileges, or duplicated release metadata were touched. Image-building logic is unchanged.

| What | Why |
|---|---|
| `preflight` job removed from both build workflows | It checked whether the actor had starred `LongQT-sea/macos-iso-builder` via 5 pages of `/users/{actor}/starred`. In any fork that check fails, so the first two runs were silently skipped and only the third run built anything. |
| `refresh-forks-list.yml` deleted | Its job was guarded by `if: github.repository_owner == 'LongQT-sea'`, so it can never run in a fork. Left in place it would only show up as a skipped run every 6 hours. |
| README links made relative | Images, the fork link and the `mkmaciso` download URLs all pointed at the upstream repo. |
| `concurrency` groups added | Two dispatches of the same workflow now queue instead of racing for the same artifact name. |
| `versions.tsv` is now the single source of truth | Release facts used to be copied into 5 places in `mkmaciso` plus a `case` block in the recovery workflow. Now there is one table. |
| `mkmaciso --list`, `--dry-run`, `--dump-versions` | `--dry-run` resolves the version and prints the plan without downloading, which is what makes the table testable in CI. |
| `tools/check-versions.sh` + `quality.yml` | Validates the table's schema and fails when it disagrees with the workflow option lists. |
| `tr -d '_- '` replaced with `sed` | `tr` treats `_` to space as a reversed range and aborts under some locales, which killed the script before it printed anything. |

Keeping this fork in sync with upstream is a `git merge` of the two workflow files; only the `preflight` job and the deleted cron workflow are expected to conflict.

---

## Adding a new macOS release

One row in `versions.tsv`, then let CI tell you what else to touch:

1. Append a row to `versions.tsv` (fields are documented at the top of the file).
2. Add the release name to the `macos_version` options in `.github/workflows/build-macos-image.yml`.
3. Run `./tools/check-versions.sh` — it reports every list that disagrees with the table.
4. Run `./mkmaciso <version> iso --dry-run` to confirm the row resolves.

Nothing in the script needs editing.

---

## Tips

For VMs, just attach the ISO as a virtual CD drive. Proxmox users — if you want better performance, look into GPU passthrough. Upstream also has [OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO) that might help with installation, and one for [Intel iGPU passthrough](https://github.com/LongQT-sea/intel-igpu-passthru) specifically.

For bootable USB drives, after you flash the DMG there will be leftover space on the drive. You can use that to create a FAT32 partition for your EFI folder if you need one.

If you're using `dd` on Linux, triple-check your target device. `dd` doesn't ask for confirmation.

## Requirements for mkmaciso

- macOS 10.9 or newer (11+ is better)
- Intel Mac recommended, Apple Silicon works but with some limitations
- 20-40GB of free space while building
- Internet connection
- sudo access
- `versions.tsv` next to the script, or `MKMACISO_DATA` pointing at it

## Credits

Apple for macOS and their update servers, [Mavericks Forever](https://mavericksforever.com/) for documenting the Mavericks recovery protocol, and the [InsanelyMac community](https://www.insanelymac.com/forum/topic/338810-create-legit-copy-of-macos-from-apple-catalog/) for their research on downloading macOS directly from Apple's catalog.

## Legal stuff

This tool downloads macOS images directly from Apple's official servers. Users are responsible for complying with [Apple's Software License Agreement](https://www.apple.com/legal/sla/). macOS is a trademark of Apple Inc.

Licensed under GPLv3.
