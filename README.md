# Project Title

A Minimal Debian Linux Setup Script for Personal Use

## Purpose

This script serves as a quick initial setup for my Debian server, intended to bridge the gap until I can provision it more fully using tools like Ansible, Terraform, or other Infrastructure as Code (IaC) solutions.

## Features

- Installs Debian Linux
- Configures networking via systemd-networkd (sets a static IP address, gateway, and DNS)
- Creates a non-root user for SSH access (useful for Ansible)
- Enables the SSH daemon and installs my public SSH key

## How to Use

1. Boot into the Debian Linux live environment

2. Run the following commands:
```bash
curl -sSL https://raw.githubusercontent.com/Tail-R/arch-minimal-setup/main/setup.sh -o setup.sh

chmod +x setup.sh

./setup.sh root_password static_ip/CIDR
```

## To-Do

- Set up an HTTP server to distribute the SSH public key

## License

MIT
