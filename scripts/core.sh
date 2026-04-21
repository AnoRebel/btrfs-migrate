#!/usr/bin/env bash
# Version: v1.0.0

ensure_grub_btrfs() {
  if command -v grub-btrfs >/dev/null; then
    echo "grub-btrfs already installed"
    return
  fi

  echo "Attempting to install grub-btrfs..."

  if command -v apt-get >/dev/null; then
    apt-get install -y grub-btrfs || true
  elif command -v pacman >/dev/null; then
    pacman -S --noconfirm grub-btrfs || true
  fi

  if ! command -v grub-btrfs >/dev/null; then
    echo "Installing grub-btrfs from source..."
    git clone https://github.com/Antynea/grub-btrfs.git /tmp/grub-btrfs
    cd /tmp/grub-btrfs && make install
  fi
}
