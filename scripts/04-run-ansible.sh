#!/usr/bin/env bash
# M3: run the Ansible playbook against Role=web instances over SSM. Run from WSL.
# Needs: scripts/setup-ansible-wsl.sh done once, AWS_PROFILE set, state/ansible.env with SSM_BUCKET.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${AWS_PROFILE:?Set AWS_PROFILE to your AWS CLI profile}"
: "${AWS_REGION:=us-east-2}"
export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

# In WSL, point boto3 at the Windows ~/.aws instead of copying credentials into Linux.
if [[ ! -f "${HOME}/.aws/config" && -n "${WSL_DISTRO_NAME:-}" ]]; then
  win_home="$(wslpath "$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')")"
  export AWS_CONFIG_FILE="${win_home}/.aws/config"
  export AWS_SHARED_CREDENTIALS_FILE="${win_home}/.aws/credentials"
fi

# shellcheck disable=SC1091
[[ -f "${HOME}/.venvs/ansible/bin/activate" ]] && source "${HOME}/.venvs/ansible/bin/activate"
command -v ansible-playbook >/dev/null || { echo "ansible-playbook not found. Run scripts/setup-ansible-wsl.sh"; exit 1; }
command -v session-manager-plugin >/dev/null || { echo "session-manager-plugin not found. Run scripts/setup-ansible-wsl.sh"; exit 1; }

STATE="${REPO_DIR}/state/ansible.env"
[[ -f "$STATE" ]] || { echo "Missing state/ansible.env (needs SSM_BUCKET=<your bucket>)."; exit 1; }
# shellcheck disable=SC1090
source "$STATE"
export ANSIBLE_SSM_BUCKET="${SSM_BUCKET:?SSM_BUCKET not set in state/ansible.env}"

cd "${REPO_DIR}/ansible"
# Repo on /mnt/c is world-writable to WSL, and Ansible ignores ansible.cfg there unless told explicitly.
export ANSIBLE_CONFIG="${REPO_DIR}/ansible/ansible.cfg"

echo "==> Inventory"
ansible-inventory --graph
echo "==> Playbook"
ansible-playbook site.yml "$@"
