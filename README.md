# system-report

A portable, read-only hardware and firmware inventory tool for Linux. It
produces a set of plain-text reports describing a machine's CPU, memory, storage
health, battery condition, firmware, and display capabilities --- one file per
subsystem --- suitable for documenting a system, archiving before a repair, or
writing an accurate listing when selling a computer.

It is **generic by design**: no vendor, model, or device node is hard-coded;
sections are emitted only when the tools they need are present; and storage and
power sections iterate over every device the kernel exposes.

## Contents

- [What it produces](#what-it-produces)
- [Design principles](#design-principles)
- [Usage](#usage)
- [Privacy: the `--private` flag](#privacy-the---private-flag)
- [Installation: Debian 13 (stable)](#installation-debian-13-stable)
- [Installation: Arch Linux](#installation-arch-linux)
- [Installation: NixOS (stable)](#installation-nixos-stable)
- [Verifying the output](#verifying-the-output)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)

## What it produces

Output goes to `./<machine-slug>-report/`, where `<machine-slug>` is derived
from `/sys/class/dmi/id/product_name` (e.g.
`laptop-13-amd-ryzen-7040series-report/`). One file per section:

| File stem            | Contents                                             | Can hold private data |
| -------------------- | ---------------------------------------------------- | --------------------- |
| `system-id-info.txt` | Manufacturer, product name, board, chassis, hostname | yes                   |
| `firmware-info.txt`  | BIOS vendor/version/date, `fwupdmgr` history         | yes                   |
| `cpu-info.txt`       | `lscpu`, CPU model                                   | no                    |
| `memory-info.txt`    | `free -h`, per-SO-DIMM size/speed/part number        | no                    |
| `pci-info.txt`       | `lspci -nnk`                                         | no                    |
| `storage-info.txt`   | `lsblk`, `smartctl -a` per disk, NVMe health logs    | yes                   |
| `power-info.txt`     | Battery cycles/capacity, PPD and/or TLP state        | no                    |
| `display-info.txt`   | DRM modes (sysfs) plus session-bound display tools   | no                    |
| `hsi-info.txt`       | `fwupdmgr security` (firmware security posture)      | no                    |

Files that can contain identifiers receive a `-private` suffix when `--private`
is used, e.g. `storage-info-private.txt`. **Do not publish those files.**

## Design principles

- **Detect, don't assume.** Sections declare the tools they need; a section is
  skipped with an explanatory note if none are present. NVMe controllers,
  batteries, and SMART-capable disks are discovered at runtime.
- **Plain text only.** ANSI color and escape sequences are stripped, and
  carriage returns removed, so files are clean when read in a forum post, a
  diff, or a plain editor. Tools that honour `NO_COLOR`, `TERM=dumb`, and
  `SYSTEMD_COLORS=0` are told to suppress color; a `strip_ansi` filter catches
  the ones that ignore those hints.
- **Failures never abort the run.** A missing tool prints
  `# (skipped --- <tool> not installed)` and the report continues.
- **Privacy is opt-in.** Identifier fields are omitted or redacted unless
  `--private` is passed.
- **Never writes to hardware.** Only read commands are issued; nothing is
  configured or changed.

## Usage

```bash
# Public report (default) into ./<machine>-report/
./system-report.sh

# Preview which sections will be emitted, and where output will land
./system-report.sh --list

# Include serials, UUIDs, hostname; writes *-private.txt files
./system-report.sh --private

# Custom output directory
./system-report.sh --private -o /tmp/fw-report

# Override the directory stem
./system-report.sh -n mylaptop
```

| Option                   | Meaning                                                                                    |
| ------------------------ | ------------------------------------------------------------------------------------------ |
| `-p`, `--private`        | Include serials, system UUID, hostname, drive serials, fwupd device IDs. Default: **off**. |
| `-o DIR`, `--outdir DIR` | Output directory (default `./<machine-slug>-report`).                                      |
| `-n STEM`, `--name STEM` | Override the output directory stem instead of using the detected model.                    |
| `-l`, `--list`           | List sections that would be emitted or skipped, then exit.                                 |
| `-h`, `--help`           | Show help.                                                                                 |

**Run it as your normal user, not with `sudo ./system-report.sh`.** The script
elevates only the commands that require root. Running the whole script as root
breaks `upower -i` (it must reach your session's D-Bus daemon) and, for the
display section, would strip the session environment.

## Privacy: the `--private` flag

Off by default. When **off**, the section runs without the identifier-bearing
commands, and a `scrub` filter additionally masks identifiers that appear inside
other tools' output --- `smartctl -a`'s `Serial Number:` header, `upower`'s
battery `serial:`, hostname and machine-ID lines, and MAC addresses.

Each private-capable file states which mode produced it:

```
# Private fields omitted --- re-run with --private to include them.
```

or

```
# WARNING: contains private details (serials). Do NOT post publicly.
```

**The `--private` run is your complete record. The public run is the one you
share.**

## Installation: Debian 13 (stable)

Most dependencies are already present on a desktop install. The following covers
the full set.

```bash
sudo apt update
sudo apt install \
  bash coreutils sed grep perl util-linux systemd \
  dmidecode pciutils \
  smartmontools nvme-cli \
  upower acpi \
  fwupd \
  x11-xserver-utils wayland-utils wlr-randr
```

| Package             | Provides                                                        | Section                     | Required?   |
| ------------------- | --------------------------------------------------------------- | --------------------------- | ----------- |
| `bash`              | shell the script runs under                                     | ---                         | required    |
| `coreutils`         | `cat`, `date`, `tr`                                             | all                         | required    |
| `sed`               | `scrub`, `strip_ansi` fallback                                  | all                         | required    |
| `grep`              | CPU model line                                                  | cpu                         | required    |
| `util-linux`        | `lsblk`                                                         | storage                     | required    |
| `systemd`           | `hostnamectl`, `systemctl`                                      | system-id, power            | required    |
| `dmidecode`         | DMI/SMBIOS tables                                               | system-id, firmware, memory | required    |
| `perl`              | preferred `strip_ansi` (more reliable escape handling than sed) | all                         | recommended |
| `pciutils`          | `lspci`                                                         | pci                         | recommended |
| `smartmontools`     | `smartctl`                                                      | storage                     | recommended |
| `nvme-cli`          | `nvme smart-log`, `nvme id-ctrl`                                | storage                     | recommended |
| `upower`            | `upower -i` battery details                                     | power                       | recommended |
| `acpi`              | `acpi -a`, `acpi -b`                                            | power                       | recommended |
| `fwupd`             | `fwupdmgr`                                                      | firmware, hsi               | recommended |
| `x11-xserver-utils` | `xrandr`                                                        | display                     | optional    |
| `wayland-utils`     | `wayland-info`                                                  | display                     | optional    |
| `wlr-randr`         | wlroots output management                                       | display                     | optional    |

**Deliberately not in the list above:**

- **`gnome-randr`** --- not packaged in Debian under any name. Upstream is a
  Rust reimplementation for GNOME/Mutter Wayland; install with
  `cargo install gnome-randr`. The section skips it gracefully if absent.
- **`sway`** --- provides `swaymsg`, but pulls an entire compositor in for one
  command. Only install if you actually run Sway.

**Power management --- read this before installing a daemon.** On Debian 13,
`power-profiles-daemon` is a **virtual package**, provided by `tuned-ppd`, an
API translation daemon that exposes the same D-Bus interface. So
`apt install power-profiles-daemon` does _not_ install the upstream daemon; it
drags in `tuned-ppd`. If you want the profile line populated:

```bash
sudo apt install tuned-ppd     # provides the power-profiles-daemon D-Bus API
# or, if you use TLP instead:
sudo apt install tlp
```

## Installation: Arch Linux

```bash
sudo pacman -S --needed \
  bash coreutils sed grep perl util-linux systemd \
  dmidecode pciutils \
  smartmontools nvme-cli \
  upower acpi \
  fwupd \
  xorg-xrandr wayland-utils wlr-randr
```

| Package         | Provides                              | Section                     | Required?   |
| --------------- | ------------------------------------- | --------------------------- | ----------- |
| `bash`          | shell                                 | ---                         | required    |
| `coreutils`     | `cat`, `date`, `tr`                   | all                         | required    |
| `sed`           | `scrub`, `strip_ansi` fallback        | all                         | required    |
| `grep`          | CPU model line                        | cpu                         | required    |
| `util-linux`    | `lsblk`                               | storage                     | required    |
| `systemd`       | `hostnamectl`, `systemctl`            | system-id, power            | required    |
| `dmidecode`     | DMI/SMBIOS tables                     | system-id, firmware, memory | required    |
| `perl`          | preferred `strip_ansi`                | all                         | recommended |
| `pciutils`      | `lspci`                               | pci                         | recommended |
| `smartmontools` | `smartctl`                            | storage                     | recommended |
| `nvme-cli`      | `nvme smart-log`, `nvme id-ctrl`      | storage                     | recommended |
| `upower`        | battery details                       | power                       | recommended |
| `acpi`          | `acpi -a`, `acpi -b`                  | power                       | recommended |
| `fwupd`         | `fwupdmgr`                            | firmware, hsi               | recommended |
| `xorg-xrandr`   | `xrandr`                              | display                     | optional    |
| `wayland-utils` | `wayland-info`                        | display                     | optional    |
| `wlr-randr`     | wlroots output management, in `extra` | display                     | optional    |

**Power management:**

```bash
sudo pacman -S power-profiles-daemon    # PPD --- recommended on FW13 AMD 7040
# or
sudo pacman -S tlp                      # only if you use TLP on other hardware
sudo systemctl enable --now power-profiles-daemon
```

`tuned-ppd` also exists in Arch `extra` and declares
`Provides: power-profiles-daemon`, so it can stand in for PPD. Install one of
the three, not several.

**Not in the official repositories:** `gnome-randr` is AUR-only.

```bash
paru -S gnome-randr     # or yay -S gnome-randr
```

`sway` provides `swaymsg` but is intentionally excluded for the same reason as
on Debian.

## Installation: NixOS (stable)

NixOS 26.05 "Yarara" is the current stable release (2026-05-30) and receives
bugfixes and security updates until 2026-12-31. The previous release, 25.11
"Xantusia", reached end-of-life on 2026-06-30.

### Option A: `shell.nix` (no flakes)

Place this beside the script:

```nix
{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  name = "system-report";

  packages = with pkgs; [
    # script runtime
    bash
    coreutils
    gnused
    gnugrep
    perl
    util-linux
    systemd          # hostnamectl, systemctl, powerprofilesctl
    # inventory
    dmidecode
    pciutils
    # storage
    smartmontools
    nvme-cli
    # power (both included in the shell; the script reports whichever is present)
    upower
    acpi
    tlp
    power-profiles-daemon
    # firmware
    fwupd
    # display / session
    xorg.xrandr
    wayland-utils
    wlr-randr
    gnome-randr
  ];

  shellHook = ''
    echo "system-report tooling ready."
    echo "  ./system-report.sh --list"
  '';
}
```

Then:

```bash
nix-shell --run ./system-report.sh
nix-shell --run "./system-report.sh --private"
```

### Option B: system configuration

If the machine runs NixOS, add the tools to `configuration.nix` and run the
script directly --- no shell needed.

```nix
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    dmidecode pciutils util-linux systemd perl
    smartmontools nvme-cli
    upower acpi
    fwupd
    # display
    xorg.xrandr wayland-utils wlr-randr
  ];

  # fwupdmgr and upower need their daemons, not just the CLIs
  services.fwupd.enable  = true;
  services.upower.enable = true;

  # Power management: enable exactly ONE per machine.
  services.power-profiles-daemon.enable = true;   # PPD --- FW13 AMD 7040 series
  # services.tlp.enable = true;                   # do not enable alongside PPD
}
```

Apply with `sudo nixos-rebuild switch`.

### NixOS notes

- **`sudo` does not inherit the nix-shell `PATH`.** The script resolves each
  tool with `command -v` to an absolute `/nix/store/...` path before invoking
  `sudo`, which sidesteps sudo's `secure_path`. Keep that behaviour if you
  modify the script.
- **Package attribute check.** `xorg.xrandr` supplies `xrandr`; if the attribute
  name differs in your `nixpkgs`, locate it with
  `nix-locate --top-level bin/xrandr`. `gnome-randr` and `wlr-randr` are
  top-level attributes.
- Enable **either** `services.power-profiles-daemon` **or** `services.tlp`,
  never both.

## Verifying the output

Before sharing anything:

```bash
# 1. No ANSI escapes should survive
grep -P '\x1b' <machine>-report/*.txt

# 2. No identifiers should appear in a public run
grep -riE 'serial|hostname|uuid|[0-9a-f]{2}(:[0-9a-f]{2}){5}' <machine>-report/*.txt
```

Step 1 should print nothing. Step 2 should show only `[redacted]` placeholders,
plus the section headers that name the fields withheld. If either check
surprises you, run `--private` and diff the two directories to see exactly what
was suppressed.

## Troubleshooting

| Symptom                                                | Cause / fix                                                                                                                                                                |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `display` listed under "Skipped sections"              | Cannot happen in current versions --- `display` is always-on via sysfs. Upgrade if you see this.                                                                           |
| Display tools print `Can't open display`               | Run the script from a terminal **inside** your graphical session. Over SSH or from a TTY only the sysfs DRM modes populate, by design.                                     |
| `upower -i` prints nothing                             | The script is being run under `sudo`. Run it as your normal user.                                                                                                          |
| `fwupdmgr: Failed to connect to daemon`                | The fwupd daemon isn't running. On NixOS set `services.fwupd.enable = true`; otherwise `sudo systemctl enable --now fwupd`.                                                |
| Battery cycle count missing or absurd                  | Known platform quirk on some boards --- ACPI `_BIX` has been reported returning zero. Report the wear percentage (`charge_full / charge_full_design`) instead, and say so. |
| A section shows `# (skipped --- X not installed)`      | The reported tool is absent. Install it from the table for your distribution and re-run.                                                                                   |
| `sudo: smartctl: command not found` inside a nix-shell | PATH propagation; the script's absolute-path resolution prevents this. If you edited that helper, restore it.                                                              |

## Known limitations

- **The `scrub` filter is pattern-based.** It masks identifier formats it
  recognises (labelled serial lines, UUIDs, MACs). A tool emitting an identifier
  in an unanticipated format could pass through. Treat a public run as _"safe
  after a quick grep"_, not as an audited guarantee.
- **`strip_ansi` is best-effort.** It handles CSI, OSC, and two-character
  escapes. Adding or changing tools may introduce sequences neither the `perl`
  nor the `sed` branch catches --- re-run the escape check after such changes.
- **`hsi-info.txt` is a security-posture report, not a fault report.** Red marks
  (platform secure boot, processor rollback protection, encrypted RAM, kernel
  lockdown, secure boot under Linux) are firmware, platform, or runtime defaults
  on many boards, not defects. The file includes a header saying so.
- **Session-bound display tools need a running session.** `wayland-info`,
  `wlr-randr`, `xrandr`, `swaymsg`, and `gnome-randr` are clients, not hardware
  probes. The sysfs block is the always-available baseline.
- **Read-only.** The script never modifies hardware state, but it does require
  `sudo` for DMI, SMART, and firmware queries.
