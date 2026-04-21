# Btrfs Migrate Tool (v1.0.0)

## Overview
Production-ready migration tool for converting Linux systems to Btrfs with optional LUKS encryption.

## Features
- Ubuntu 24.04+ and Arch Linux
- Btrfs subvolumes (customizable)
- LUKS encryption (safe mode only)
- GRUB / systemd-boot support
- Optional Snapper / Timeshift
- Optional grub-btrfs (manual install supported)
- SSD-aware mount options
- Interactive CLI (Go + Bubble Tea)

## grub-btrfs Note
grub-btrfs is NOT always in official repos.
We support:
- Auto-install if available
- Fallback: clone from GitHub and install manually

## Usage (CLI)
Run:
  btrfs-migrate

## Safety
- Refuses unsafe operations
- Requires explicit confirmation
- Logs to /var/log/btrfs-migrate.log

## Version
v1.0.0
