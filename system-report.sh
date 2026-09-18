#!/usr/bin/env bash
# system-report.sh — portable hardware/firmware inventory for documenting or
# listing a computer for sale.
#
# Generic by design:
#   * no vendor, model, or device node is hard-coded
#   * each section is emitted only if the tools it needs are present
#   * storage/power sections iterate over whatever devices are detected
#   * TLP is reported only when TLP is installed; PPD state is reported too
#
# Usage:
#   ./system-report.sh                  # public report  (default)
#   ./system-report.sh --private        # add serials / UUIDs / hostname
#   ./system-report.sh --list           # show which sections will be emitted
#   ./system-report.sh -p -o /tmp/out   # private report into /tmp/out
#   ./system-report.sh -n mybox         # force the output directory stem
#
# Output: one plain-text file per section, in ./<machine>-report/
#   system-id-info.txt   cpu-info.txt   memory-info.txt   pci-info.txt
#   firmware-info.txt    storage-info.txt   power-info.txt
#   display-info.txt     hsi-info.txt
# Stems that can hold identifiers get a "-private" suffix when --private is on.
# Do not post the -private files publicly.

set -uo pipefail          # no -e: optional tools may be absent

INCLUDE_PRIVATE=false
OUTDIR=""
FORCED_NAME=""
LIST_ONLY=false

usage() {
  cat << 'EOF'
Usage: system-report.sh [options]

Options:
-p, --private      Include private details: machine serial, system UUID,
hostname, drive serials, fwupd device IDs. Default: OFF.
-o, --outdir DIR   Directory for the reports (default: ./<machine>-report)
-n, --name STEM    Override the output directory stem (default: detected model)
-l, --list         List which sections would be emitted, then exit
-h, --help         Show this help.
EOF
}

# Distinguishes "is the tool installed" from "will it work right now".
have_session() {
  case "$1" in
    x11)     [ -n "${DISPLAY:-}" ] ;;
    wayland) [ -n "${WAYLAND_DISPLAY:-}" ] ;;
    sway)    [ -n "${SWAYSOCK:-}" ] ;;
    *) return 1 ;;
  esac
}

section_display() {
  # --- Always available: kernel DRM sysfs. No tools, no display server, no root.
  local m
  for m in /sys/class/drm/*/modes; do
    [ -r "$m" ] || continue
    printf '\n# %s\n' "$m"
    run cat "$m"
  done
  [ -r /sys/class/drm/version ] && run cat /sys/class/drm/version

  # --- Session-bound tools, each guarded so absence is explained, not errored.

  # X11
  if have_session x11; then
    run xrandr
    run xrandr --verbose
  else
    printf '\n# xrandr skipped — no X11 session (DISPLAY unset).\n'
    printf '#   sysfs /sys/class/drm/*/modes above still lists supported modes.\n'
  fi

  # Any Wayland compositor
  if have_session wayland; then
    run wayland-info
  else
    printf '\n# wayland-info skipped — no Wayland session (WAYLAND_DISPLAY unset).\n'
  fi

  # wlroots-based compositors (Sway, River, labwc, ...)
  if have_session wayland; then
    run wlr-randr
    run wlr-randr --json
  fi

  # Sway specifically
  if have_session sway; then
    run swaymsg -t get_outputs
  else
    printf '\n# swaymsg skipped — not running under Sway (SWAYSOCK unset).\n'
  fi

  # GNOME/Mutter Wayland
  if have_session wayland; then
    run gnome-randr
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -p | --private) INCLUDE_PRIVATE=true ;;
    -o | --outdir)
      OUTDIR="${2:?--outdir requires an argument}"
      shift
      ;;
    -n | --name)
      FORCED_NAME="${2:?--name requires an argument}"
      shift
      ;;
    -l | --list) LIST_ONLY=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

# ---------- force plain text ------------------------------------------------
# Belt: ask tools that honor these to disable color and paging.
export NO_COLOR=1            # no-color.org — a hint, not a guarantee
export TERM=dumb
export SYSTEMD_COLORS=0
export SYSTEMD_PAGER=cat
export PAGER=cat
export LS_COLORS=
export GREP_COLORS=
# Braces: strip_ansi() below removes anything that ignored the above.

# ---------- capability / device detection -----------------------------------
have()     { command -v -- "$1" > /dev/null 2>&1; }
have_any() {
  local t
  for t in "$@"; do have "$t" && return 0; done
  return 1
}

slugify() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' |
    sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-//' -e 's/-$//'
}

# Model name from sysfs (readable without root), then hostname, then fallback.
machine_name() {
  if [ -n "$FORCED_NAME" ]; then
    printf '%s' "$FORCED_NAME"
    return
  fi
  local p=/sys/class/dmi/id/product_name
  if [ -r "$p" ]; then
    cat "$p"
    return
  fi
  hostname 2> /dev/null || printf 'system'
}

MACHINE_SLUG="$(slugify "$(machine_name)")"
[ -n "$MACHINE_SLUG" ] || MACHINE_SLUG=system
: "${OUTDIR:=./${MACHINE_SLUG}-report}"

# NVMe controllers (skip namespace nodes like nvme0n1)
mapfile -t NVME_CTRLS < <(
  for d in /dev/nvme[0-9]*; do
    [ -e "$d" ] || continue
    case "$d" in *n[0-9]*) continue ;; esac
    printf '%s\n' "$d"
  done
)

# Batteries
mapfile -t BATTERIES < <(
  for d in /sys/class/power_supply/*; do
    [ -r "$d/type" ] || continue
    [ "$(cat "$d/type" 2> /dev/null)" = Battery ] && printf '%s\n' "$d"
  done
)

# ---------- output filters --------------------------------------------------
ESC=$'\033'

if have perl; then
  strip_ansi() {
    perl -pe '
s/\e\[[0-9;?]*[ -\/]*[@-~]//g;   # CSI ... final byte
s/\e\][^\a]*(?:\a|\e\\)//g;      # OSC ... BEL or ST
s/\e[@-Z\\-_]//g;                # 2-char escapes
s/\r//g;                         # progress-line CR
s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g;
'
  }
else
  strip_ansi() {
    sed -E \
      -e "s/${ESC}\[[0-9;?]*[ -\/]*[@-~]//g" \
      -e "s/${ESC}[]()#][A-Za-z0-9]//g" \
      -e "s/${ESC}[@-Z\\\\-_]//g" | tr -d '\r'
  }
fi

# Mask identifiers that appear inside otherwise-public output (--private OFF).
scrub() {
  sed -E \
    -e 's/^([[:space:]]*(Serial Number|Serial)[[:space:]]*:).*/\1 [redacted]/I' \
    -e 's/^([[:space:]]*(sn|serial)[[:space:]]*:).*/\1 [redacted]/I' \
    -e 's/^([[:space:]]*Static hostname[[:space:]]*:).*/\1 [redacted]/I' \
    -e 's/^([[:space:]]*(Machine ID|Boot ID)[[:space:]]*:).*/\1 [redacted]/I' \
    -e 's/^([[:space:]]*UUID[[:space:]]*:).*/\1 [redacted]/I' \
    -e 's/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/[mac redacted]/g'
}

# ---------- command helpers -------------------------------------------------
_run() {
  local pre="$1" name="$2"
  shift 2
  if ! have "$name"; then
    printf '\n$ %s%s %s\n# (skipped — %s not installed)\n' \
      "${pre:+$pre }" "$name" "$*" "$name"
    return 0
  fi
  # absolute path so sudo finds tools installed outside its secure_path
  local path
  path="$(command -v -- "$name")"
  printf '\n$ %s%s %s\n' "${pre:+$pre }" "$name" "$*"
  # shellcheck disable=SC2086
  $pre "$path" "$@" 2>&1 || printf '!! %s exited %s (continuing)\n' "$name" "$?"
}
run()      { _run ""   "$@"; }
run_root() { _run sudo "$@"; }

priv() { if $INCLUDE_PRIVATE; then "$@"; fi; }

# ---------- sections --------------------------------------------------------
section_system_id() {
  run_root dmidecode -s system-manufacturer
  run_root dmidecode -s system-product-name
  run_root dmidecode -s system-version
  run_root dmidecode -s baseboard-manufacturer
  run_root dmidecode -s baseboard-product-name
  run_root dmidecode -s baseboard-version
  run_root dmidecode -s chassis-type
  priv run_root dmidecode -s system-serial-number
  priv run_root dmidecode -s system-uuid
  run hostnamectl
}

section_firmware() {
  run_root dmidecode -s bios-vendor
  run_root dmidecode -s bios-version
  run_root dmidecode -s bios-release-date
  run_root dmidecode -t bios
  if have fwupdmgr; then
    run_root fwupdmgr get-history
    priv run_root fwupdmgr get-devices
  fi
}

section_cpu() {
  run lscpu
  run grep -m1 'model name' /proc/cpuinfo
}

section_memory() {
  run    free -h
  run_root dmidecode -t memory
}

section_pci() {
  run lspci -nnk
}

section_storage() {
  run lsblk -d -o NAME,MODEL,SIZE,ROTA,TRAN
  run lsblk  -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
  run lsblk -D -o NAME,DISC-ALN,DISC-GRAN,DISC-MAX,DISC-ZERO

  # Every disk smartctl can see, whatever the transport (SATA/NVMe/USB).
  if have smartctl; then
    local dev
    while read -r dev _rest; do
      [ -n "${dev:-}" ] || continue
      run_root smartctl -a "$dev"
      priv run_root smartctl -i "$dev" # serial / WWN
    done < <(sudo smartctl --scan 2> /dev/null || smartctl --scan 2> /dev/null)
    run_root smartctl --scan
  fi

  # NVMe-native health log, one entry per detected controller.
  # NOTE: /dev/nvmeX is the controller (ioctl/admin), /dev/nvmeXnY the namespace.
  local ctrl
  for ctrl in ${NVME_CTRLS[@]+"${NVME_CTRLS[@]}"}; do
    run_root nvme smart-log "$ctrl"
    priv run_root nvme id-ctrl -H "$ctrl"
  done
  run nvme --version

  priv run_root nvme list                     # model + serial + firmware
  priv run lsblk -d -o NAME,MODEL,SERIAL,WWN,SIZE,ROTA,TRAN
}

section_power() {
  local b f
  for b in ${BATTERIES[@]+"${BATTERIES[@]}"}; do
    printf '\n# battery device: %s\n' "$b"
    run cat "$b/uevent"
    for f in status capacity cycle_count charge_full charge_full_design \
      energy_full energy_full_design power_now energy_now; do
      [ -r "$b/$f" ] && run cat "$b/$f"
    done
  done

  run upower -e
  local bat
  bat="$(upower -e 2> /dev/null | grep -i bat | head -n1)"
  [ -n "${bat:-}" ] && run upower -i "$bat"
  run acpi -a
  run acpi -b

  # Power-management stack. PPD and TLP are alternatives on most distros, so
  # report whichever is present rather than assuming either.
  run powerprofilesctl get
  run systemctl show -p ActiveState power-profiles-daemon

  if have tlp; then
    printf '\n# TLP detected — reporting its state.\n'
    run_root tlp-stat -s
    run_root tlp-stat -b
    run tlp-stat -c
  fi
  run systemctl show -p ActiveState tlp
}

section_display() {
  local m
  for m in /sys/class/drm/*/modes; do
    [ -r "$m" ] && run cat "$m"
  done
  run xrandr
  run xrandr --verbose
  run wlr-randr
  run swaymsg -t get_outputs
}

section_hsi() {
  printf '# HSI = firmware security posture, not a fault report.\n'
  printf '# Red marks (platform secure boot, rollback protection, encrypted RAM,\n'
  printf '# secure boot / kernel lockdown under Linux) are firmware, platform, or\n'
  printf '# runtime defaults on many boards. Not necessarily defects.\n'
  run_root fwupdmgr security
}

# ---------- section registry ------------------------------------------------
# stem | function | can hold private data | tools (ANY of these enables it)
declare -a SEC_STEM=() SEC_FN=() SEC_PRIVCAP=() SEC_NEEDS=()
add_section() {
  SEC_STEM+=("$1")
  SEC_FN+=("$2")
  SEC_PRIVCAP+=("$3")
  SEC_NEEDS+=("${4:-}")
}

add_section system-id  section_system_id  yes "dmidecode"
add_section firmware   section_firmware   yes "dmidecode,fwupdmgr"
add_section cpu        section_cpu        no  "lscpu"
add_section memory     section_memory     no  "dmidecode,free"
add_section pci        section_pci        no  "lspci"
add_section storage    section_storage    yes "smartctl,lsblk,nvme"
add_section power      section_power      no  "upower,acpi,tlp,powerprofilesctl"
add_section display    section_display    no  ""      # always: sysfs fallback
add_section hsi        section_hsi        no  "fwupdmgr"

section_enabled() {
  local needs="$1" t
  [ -z "$needs" ] && return 0
  local IFS=','
  for t in $needs; do have "$t" && return 0; done
  return 1
}

print_sections() {
  local i stem needs
  for i in "${!SEC_STEM[@]}"; do
    stem="${SEC_STEM[$i]}"
    needs="${SEC_NEEDS[$i]}"
    if section_enabled "$needs"; then
      printf 'include  %-10s (tools: %s)\n' "$stem" "${needs:-always}"
    else
      printf 'skip     %-10s (needs any of: %s)\n' "$stem" "$needs"
    fi
  done
}

if $LIST_ONLY; then
  printf 'machine: %s\noutput:  %s\nprivate: %s\n\n' \
    "$MACHINE_SLUG" "$OUTDIR" "$INCLUDE_PRIVATE"
  print_sections
  exit 0
fi

# ---------- driver ----------------------------------------------------------
mkdir -p "$OUTDIR"
private_files=()
skipped=()

for i in "${!SEC_STEM[@]}"; do
  stem="${SEC_STEM[$i]}"
  fn="${SEC_FN[$i]}"
  privcap="${SEC_PRIVCAP[$i]}"
  needs="${SEC_NEEDS[$i]}"

  if ! section_enabled "$needs"; then
    skipped+=("$stem (needs any of: $needs)")
    continue
  fi

  file="$OUTDIR/${stem}-info.txt"
  if $INCLUDE_PRIVATE && [ "$privcap" = yes ]; then
    file="$OUTDIR/${stem}-info-private.txt"
    private_files+=("$file")
  fi

  printf 'writing %-52s ... ' "$file"
  {
    printf '# machine: %s\n' "$MACHINE_SLUG"
    printf '# section: %s\n# generated: %s\n' "$stem" "$(date -Is)"
    printf '# plain text: ANSI escape sequences stripped\n'
    if [ "$privcap" = yes ]; then
      if $INCLUDE_PRIVATE; then
        printf '# WARNING: contains private details (serials). Do NOT post publicly.\n'
      else
        printf '# Private fields omitted — re-run with --private to include them.\n'
      fi
    fi
    "$fn"
  } 2>&1 | strip_ansi | { if $INCLUDE_PRIVATE; then cat; else scrub; fi; } > "$file"
  printf 'done\n'
done

printf '\nReports in %s/  (private mode: %s)\n' "$OUTDIR" "$INCLUDE_PRIVATE"
if [ "${#skipped[@]}" -gt 0 ]; then
  printf 'Skipped sections (tools absent):\n'
  printf '  %s\n' "${skipped[@]}"
fi
if [ "${#private_files[@]}" -gt 0 ]; then
  printf 'Files containing private details:\n'
  printf '  %s\n' "${private_files[@]}"
fi
