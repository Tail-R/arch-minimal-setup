#! /usr/bin/env bash

if [ "${EUID}" -ne 0 ]; then
    echo "ERROR: You are not super user" >&2
    exit 1
fi

if [ "${#}" -lt 2 ]; then
    echo "Usage: $0 <root_password> <static_ip/CIDR> [gateway_ip]" >&2
    exit 1
fi

ROOT_PASS="${1}"
STATIC_IP="${2}"

if ! [[ "${STATIC_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$ ]]; then
    echo "ERROR: Static IP must be in CIDR format, e.g. 192.168.1.100/24" >&2
    exit 1
fi

set -e

#
# Partitioning
#
ROOT_DISK=$(findmnt -no SOURCE / | sed -E 's|[0-9]+$||')
DISK=$(lsblk -dpno NAME,TRAN | \
    grep -E "/dev/sd|/dev/nvme" | \
    grep -v -E "usb|mmc|${ROOT_DISK#/dev/}" | \
    head -n1 | awk '{print $1}')

EFI_LABEL="EFI"
ROOT_LABEL="ROOT"

echo "!!! This will ERASE all data on ${DISK} !!!"
read -p "Are you sure? (yes/NO): " confirm

if [[ "${confirm}" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

# Remove GPT and MBR
sgdisk --zap-all "${DISK}"

# Destroy boot sector
dd if=/dev/zero of="${DISK}" bs=512 count=2048 status=progress

# Create EFI system partition (512MB)
sgdisk --new=1:0:+512M --typecode=1:ef00 --change-name=1:"${EFI_LABEL}" "${DISK}"

# Create root partition
sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:"${ROOT_LABEL}" "${DISK}"

# Wait for udev to reflect partition labels
udevadm settle

EFI_DEV="/dev/disk/by-partlabel/${EFI_LABEL}"
ROOT_DEV="/dev/disk/by-partlabel/${ROOT_LABEL}"

for dev in "${EFI_DEV}" "${ROOT_DEV}"; do
    if [ ! -b "${dev}" ]; then
        echo "ERROR: ${dev} does not exist" >&2
        exit 1
    fi
done

#
# Format devices
#
mkfs.vfat -F32 "${EFI_DEV}"
mkfs.ext4 -F "${ROOT_DEV}"

#
# Mount devices
#
mkdir -p /mnt /mnt/boot/efi
mount "${ROOT_DEV}" /mnt
mount "${EFI_DEV}" /mnt/boot/efi

#
# Install Arch btw :3
#
pacstrap /mnt base linux linux-firmware sudo vim

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
echo "root:${ROOT_PASS}" | chpasswd

ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc

sed -i 's/^#[[:space:]]*en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

pacman -Sy --noconfirm grub efibootmgr dosfstools os-prober mtools intel-ucode networkmanager wpa_supplicant iw openssh

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB_UEFI
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable NetworkManager
systemctl enable sshd

IFACE=\$(nmcli device | awk '/ethernet|wifi/ {print \$1; exit}')
GATEWAY="${3:-${STATIC_IP%.*}.1}"

nmcli con add type ethernet ifname "\$IFACE" con-name static-conn
nmcli con mod static-conn ipv4.addresses "${STATIC_IP}"
nmcli con mod static-conn ipv4.gateway "${GATEWAY}"
nmcli con mod static-conn ipv4.dns 8.8.8.8
nmcli con mod static-conn ipv4.method manual
nmcli con up static-conn
EOF
