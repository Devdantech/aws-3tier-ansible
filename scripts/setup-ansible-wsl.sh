#!/usr/bin/env bash
# One-time Ansible control-node setup inside WSL (Ubuntu). Ansible can't run natively on Windows.
# Installs: ansible-core + boto3 in a venv, the amazon.aws collection, and the Session Manager plugin.
# Credentials are not copied: the AWS config/credentials files are read from the Windows ~/.aws.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${HOME}/.venvs/ansible"

sudo apt-get update -y
sudo apt-get install -y python3-venv python3-pip curl

if ! command -v session-manager-plugin >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/session-manager-plugin.deb" \
    "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb"
  sudo dpkg -i "${tmp}/session-manager-plugin.deb"
  rm -rf "$tmp"
fi

python3 -m venv "$VENV"
"${VENV}/bin/pip" install --upgrade pip
"${VENV}/bin/pip" install "ansible-core>=2.17,<2.20" boto3 botocore
"${VENV}/bin/ansible-galaxy" collection install -r "${REPO_DIR}/ansible/requirements.yml"

echo
echo "Done. Before running Ansible in a new WSL shell:"
echo "  source ${VENV}/bin/activate"
echo "  (scripts/04-run-ansible.sh does this for you)"
