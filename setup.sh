#! /usr/bin/env bash

if [ "${EUID}" -ne 0 ]; then
    echo "ERROR: You are not super user" >&2
    exit 1
fi

if [ "${#}" -lt 2 ]; then
    echo "Usage: $0 <admin_password> <static_ip/CIDR>" >&2
    exit 1
fi

# Admin user
ADMIN=admin

# Admin passwd
ADMIN_PASS="${1}"

# Desired IPv4 Address
ADDRESS="${2}"

# Key to SSH from controller device
SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq4r93ZNZfSEFIyLHHYtwXYu3vN4ZdPXH/DDdD4W1hx ansible@mycluster"
SSH_CONF="/etc/ssh/sshd_config"

# The packages will be installed to the system
REQUIRED_PKGS="
sudo
vim
build-essential
python3
cmake
systemd-resolved
"

set -euo pipefail

# IP Address validation
if ! [[ "${ADDRESS}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$ ]]; then
    echo "ERROR: Static IP must be in CIDR format, e.g. 192.168.1.100/24" >&2
    exit 1
fi

# Use the xxx.xxx.xxx.1 address of the given subnet as the gateway address
GATEWAY="$(echo "${ADDRESS}" | cut -d'/' -f1 | sed -E 's|([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+|\1.1|')"
DNS="${GATEWAY}" # or just "8.8.8.8"

# Get the name of the first matching network interface
IFACE=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") print \$(i+1)}')

# Create .network file
cat <<EOF > /etc/systemd/network/20-wired.network
[Match]
Name=${IFACE}

[Network]
DHCP=no
Address=${ADDRESS}
Gateway=${GATEWAY}
DNS=${DNS}
EOF

#
# Install required packages
#
apt-get update
apt-get install -y ${REQUIRED_PKGS}

#
# Create admin user if not exists
#
if ! id -u ${ADMIN} >/dev/null 2>&1; then
    useradd -m -G sudo -s /bin/bash ${ADMIN}
fi

# Set passwd
echo "${ADMIN}:${ADMIN_PASS}" | chpasswd
cp /etc/sudoers /etc/sudoers.backup &&

# Allow root permission
mkdir -p /etc/sudoers.d
echo "${ADMIN} ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/${ADMIN}
chmod 440 /etc/sudoers.d/${ADMIN}

#
# SSH config
#
mkdir -p /home/${ADMIN}/.ssh
echo "${SSH_PUBKEY}" >> /home/${ADMIN}/.ssh/authorized_keys
chown -R ${ADMIN}:${ADMIN} /home/${ADMIN}/.ssh
chmod 700 /home/${ADMIN}/.ssh
chmod 600 /home/${ADMIN}/.ssh/authorized_keys

# Edit sshd_config
sed -i 's/^#\?\s*PasswordAuthentication\s\+.*/PasswordAuthentication no/' ${SSH_CONF}
sed -i 's/^#\?\s*PermitRootLogin\s\+.*/PermitRootLogin prohibit-password/' ${SSH_CONF}
sed -i 's/^#\?\s*PubkeyAuthentication\s\+.*/PubkeyAuthentication yes/' ${SSH_CONF}

grep -q '^PasswordAuthentication' ${SSH_CONF} || echo 'PasswordAuthentication no' >> ${SSH_CONF}
grep -q '^PermitRootLogin' ${SSH_CONF} || echo 'PermitRootLogin prohibit-password' >> ${SSH_CONF}
grep -q '^PubkeyAuthentication' ${SSH_CONF} || echo 'PubkeyAuthentication yes' >> ${SSH_CONF}

#
# Enable services
#
systemctl enable systemd-resolved
systemctl enable systemd-networkd
systemctl enable ssh

#
# Restart services
#
systemctl restart systemd-resolved
systemctl restart systemd-networkd
systemctl restart ssh
