# SPDX-FileCopyrightText: 2026 sudorook
#
# SPDX-License-Identifier: GPL-3.0-or-later
{pkgs ? import <nixpkgs> {}}:
pkgs.mkShell {
  name = "system-report";

  packages = with pkgs; [
    acpi
    bash
    coreutils
    dmidecode
    fwupd
    gnome-randr
    gnugrep
    gnused
    nvme-cli
    pciutils
    perl
    power-profiles-daemon
    smartmontools
    systemd
    tlp
    upower
    util-linux
    wayland-utils
    wlr-randr
    xorg.xrandr
  ];

  shellHook = ''
    echo "system-report tooling ready."
    echo "  ./system-report.sh --list"
  '';
}
