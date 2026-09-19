{pkgs ? import <nixpkgs> {}}:
pkgs.mkShell {
  name = "system-report";

  packages = with pkgs; [
    acpi
    bash
    coreutils
    dmidecode
    fwupd
    gnome-randr # GNOME/Mutter Wayland  [^f7594a]
    gnugrep
    gnused # scrub() and the strip_ansi() fallback
    nvme-cli # nvme list / id-ctrl / smart-log
    pciutils
    perl # preferred strip_ansi() path
    power-profiles-daemon
    smartmontools # smartctl
    systemd # hostnamectl, systemctl, powerprofilesctl
    tlp # only reported if installed; NOT advised on FW13 AMD 7040
    upower
    util-linux # lsblk
    wayland-utils # wayland-info          — any Wayland compositor [^528300]
    wlr-randr # wlroots compositors   [^cfeafa]
    xorg.xrandr # X11 (xrandr)          — needs DISPLAY
  ];

  shellHook = ''
    echo "system-report tooling ready."
    echo "  ./system-report.sh --list"
  '';
}
