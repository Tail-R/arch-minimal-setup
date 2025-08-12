#! /usr/bin/env bash

SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq4r93ZNZfSEFIyLHHYtwXYu3vN4ZdPXH/DDdD4W1hx ansible@mycluster"
SSH_CONF="/etc/ssh/sshd_config"

ADMIN="admin"

if [ "${EUID}" -ne 0 ]; then
    echo "ERROR: You are not super user" >&2
    exit 1
fi

if [ "${#}" -lt 2 ]; then
    echo "Usage: $0 <root_password> <static_ip/CIDR>" >&2
    exit 1
fi

set -euo pipefail

ROOT_PASS="${1}"
ADDRESS="${2}"

if ! [[ "${ADDRESS}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$ ]]; then
    echo "ERROR: Static IP must be in CIDR format, e.g. 192.168.1.100/24" >&2
    exit 1
fi

GATEWAY="$(echo "${ADDRESS}" | cut -d'/' -f1 | sed -E 's|([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+|\1.1|')"
DNS="${GATEWAY}" # or just "8.8.8.8"

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

ROOT_DEV=$(lsblk -ln -o NAME,PARTLABEL | awk "\$2==\"${ROOT_LABEL}\" {print \"/dev/\"\$1}")
EFI_DEV=$(lsblk -ln -o NAME,PARTLABEL | awk "\$2==\"${EFI_LABEL}\" {print \"/dev/\"\$1}")

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
mkdir -p /mnt
mount "${ROOT_DEV}" /mnt

mkdir -p /mnt/boot/efi
mount "${EFI_DEV}" /mnt/boot/efi

#
# Install Arch btw :3
#
pacman-key --init
pacman-key --populate archlinux

pacstrap /mnt base base-devel linux linux-firmware sudo openssh vim python3

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
echo "root:${ROOT_PASS}" | chpasswd

ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc

sed -i 's/^#[[:space:]]*en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

pacman -Sy --noconfirm archlinux-keyring
pacman-key --init
pacman-key --populate archlinux
pacman -Sy --noconfirm grub efibootmgr dosfstools os-prober mtools intel-ucode

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB_UEFI
grub-mkconfig -o /boot/grub/grub.cfg

IFACE=\$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") print \$(i+1)}')

cat <<EOL > /etc/systemd/network/20-wired.network
[Match]
Name=\${IFACE}

[Network]
DHCP=no
Address=${ADDRESS}
Gateway=${GATEWAY}
DNS=${DNS}
EOL

useradd -m -G wheel -s /bin/bash ${ADMIN}
echo "${ADMIN}:${ROOT_PASS}" | chpasswd
cp /etc/sudoers /etc/sudoers.backup &&
sed -i 's/^# \(%wheel ALL=(ALL:ALL) ALL\)/\1/' /etc/sudoers


mkdir -p /home/${ADMIN}/.ssh
echo "${SSH_PUBKEY}" >> /home/${ADMIN}/.ssh/authorized_keys
chown -R ${ADMIN}:${ADMIN} /home/${ADMIN}/.ssh
chmod 700 /home/${ADMIN}/.ssh
chmod 600 /home/${ADMIN}/.ssh/authorized_keys

sed -i 's/^#\?\s*PasswordAuthentication\s\+.*/PasswordAuthentication no/' ${SSH_CONF}
sed -i 's/^#\?\s*PermitRootLogin\s\+.*/PermitRootLogin prohibit-password/' ${SSH_CONF}
sed -i 's/^#\?\s*PubkeyAuthentication\s\+.*/PubkeyAuthentication yes/' ${SSH_CONF}

grep -q '^PasswordAuthentication' ${SSH_CONF} || echo 'PasswordAuthentication no' >> ${SSH_CONF}
grep -q '^PermitRootLogin' ${SSH_CONF} || echo 'PermitRootLogin prohibit-password' >> ${SSH_CONF}
grep -q '^PubkeyAuthentication' ${SSH_CONF} || echo 'PubkeyAuthentication yes' >> ${SSH_CONF}

systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable sshd

EOF