!/usr/bin/env bash

#
# NixOS install script synthesized from:
#
#   - Erase Your Darlings (https://grahamc.com/blog/erase-your-darlings)
#   - ZFS Datasets for NixOS (https://grahamc.com/blog/nixos-on-zfs)
#   - NixOS Manual (https://nixos.org/nixos/manual/)
#
# It expects the name of the block device (e.g. 'sda') to partition
# and install NixOS on. The script must be executed as root.
#
# Example: `sudo ./install.sh nvme0n1`
#

set -euo pipefail

################################################################################

export COLOR_RESET="\033[0m"
export BOLD_RED="\033[31m"
export BOLD_GREEN="\033[32m"

function log_error {
    echo -e "${BOLD_RED}ERROR:${COLOR_RESET} $1"
}

function log_info {
    echo -e "${BOLD_GREEN}INFO:${COLOR_RESET} $1"
}

################################################################################

if [[ -z "${1-}" ]]; then
    log_error "Missing argument. Expected block device name, e.g. 'sda'"
    exit 1
fi

export DISK_PATH="/dev/$1"

if ! [[ -b "${DISK_PATH}" ]]; then
    log_error "Invalid argument: '${DISK_PATH}' is not a block special file"
    exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
    log_error "Must run as root"
    exit 1
fi

export ZFS_POOL="rpool"

export ZFS_EPHEMERAL="${ZFS_POOL}/ephemeral"
export ZFS_DS_ROOT="${ZFS_EPHEMERAL}/root"
export ZFS_DS_NIX="${ZFS_EPHEMERAL}/nix"

export ZFS_PERSISTENT="${ZFS_POOL}/persistent"
export ZFS_DS_HOME="${ZFS_PERSISTENT}/home"
export ZFS_DS_STATE="${ZFS_PERSISTENT}/state"

export ZFS_DS_ROOT_BLANK_SNAPSHOT="${ZFS_DS_ROOT}@blank"

################################################################################

log_info "Creating GPT, boot partition, and ZFS pool partition"
parted "${DISK_PATH}" -- mklabel gpt
parted "${DISK_PATH}" -- mkpart ESP fat32 1MiB 512MiB
parted "${DISK_PATH}" -- set 1 boot on
parted "${DISK_PATH}" -- mkpart primary 512MiB 100%
export DISK_PART_BOOT="${DISK_PATH}p1"
export DISK_PART_ROOT="${DISK_PATH}p2"

log_info "Formatting boot partition"
mkfs.fat -F 32 -n BOOT "${DISK_PART_BOOT}"

log_info "Creating ZFS pool '${ZFS_POOL}' for '${DISK_PART_ROOT}'"
zpool create -o ashift=12 -O compression=on "${ZFS_POOL}" "${DISK_PART_ROOT}"
zfs set compression=on "${ZFS_POOL}"

log_info "Creating ZFS datasets"
zfs create \
    -p -o mountpoint=legacy -o xattr=sa -o acltype=posixacl "${ZFS_DS_ROOT}"
zfs snapshot "${ZFS_DS_ROOT_BLANK_SNAPSHOT}"
zfs create -p -o mountpoint=legacy -o atime=off "${ZFS_DS_NIX}"
zfs create -p \
    -o mountpoint=legacy \
    -o com.sun:auto-snapshot=true \
    -o encryption=aes-256-gcm \
    -o keyformat=passphrase \
    "${ZFS_DS_HOME}"
zfs create -p \
    -o mountpoint=legacy \
    -o com.sun:auto-snapshot=true \
    -o encryption=aes-256-gcm \
    -o keyformat=passphrase \
    "${ZFS_DS_STATE}"

log_info "Mounting everything under /mnt"
mount -t zfs "${ZFS_DS_ROOT}" /mnt
mkdir /mnt/boot /mnt/nix /mnt/home /mnt/state
mount -t vfat "${DISK_PART_BOOT}" /mnt/boot
mount -t zfs "${ZFS_DS_NIX}" /mnt/nix
mount -t zfs "${ZFS_DS_HOME}" /mnt/home
mount -t zfs "${ZFS_DS_STATE}" /mnt/state

log_info "Generating NixOS configuration (/mnt/etc/nixos/*.nix)"
nixos-generate-config --root /mnt
mkdir -p /mnt/state/etc/nixos
mv /mnt/etc/nixos/hardware-configuration.nix /mnt/state/etc/nixos/
mv /mnt/etc/nixos/configuration.nix \
   /mnt/state/etc/nixos/configuration.nix.original
cp "$0" /mnt/state/etc/nixos/install.sh.original

log_info "Enter user name"
read -r USER_NAME

log_info "Enter host name"
read -r HOST_NAME

log_info "Writing NixOS configuration to /state/etc/nixos/"
cat <<EOF > /mnt/state/etc/nixos/configuration.nix
{ config, pkgs, lib, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
    ];

  nix.nixPath =
    [
      "nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos"
      "nixos-config=/state/etc/nixos/configuration.nix"
      "/nix/var/nix/profiles/per-user/root/channels"
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # firmware
  nixpkgs.config.allowUnfree = true;
  hardware.enableAllFirmware = true;

  # source: https://grahamc.com/blog/erase-your-darlings
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    zfs rollback -r ${ZFS_DS_ROOT_BLANK_SNAPSHOT}
  '';

  boot.zfs = {
     requestEncryptionCredentials = true;
  };

  networking.hostId = "$(head -c 8 /etc/machine-id)";
  networking.hostName = "${HOST_NAME}";
  networking.useDHCP = false;

  environment.systemPackages = with pkgs;
    [
      vim wget git firefox
    ];

  services.xserver.enable = true;
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;

  services.zfs = {
    autoScrub.enable = true;
    autoSnapshot.enable = true;
  };

  environment.gnome.excludePackages = [
    pkgs.gnome.cheese pkgs.gnome-photos pkgs.gnome.gnome-music pkgs.gnome.gedit
    pkgs.epiphany pkgs.gnome.gnome-characters pkgs.gnome.totem pkgs.gnome.tali
    pkgs.gnome.iagno pkgs.gnome.hitori pkgs.gnome.atomix pkgs.gnome-tour
    pkgs.gnome.geary
  ];

  users = {
    mutableUsers = false;
    users = {
      root = {
        initialPassword = "password";
      };

      ${USER_NAME} = {
        isNormalUser = true;
        createHome = true;
        initialPassword = "password";
	extraGroups = [ "wheel" ];
	group = "users";
	uid = 1000;
	home = "/home/${USER_NAME}";
	useDefaultShell = true;
      };
    };
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.11"; # Did you read the comment?

}
EOF

log_info "Installing NixOS to /mnt ..."
ln -s /mnt/state/etc/nixos/configuration.nix /mnt/etc/nixos/configuration.nix
nixos-install -I "nixos-config=/mnt/state/etc/nixos/configuration.nix" --no-root-passwd  # already prompted for and configured password
