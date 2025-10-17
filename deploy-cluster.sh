#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INVENTORY_FILE="${SCRIPT_DIR}/inventory.ini"
PLAYBOOK_DIR="${SCRIPT_DIR}/playbook"
SSH_USERNAME=""
SSH_USER_PASSWORD=""
SSH_KEY_PATH=""
SSH_NODES=()
SSH_MASTER_NODES=()
SSH_WORKER_NODES=()

COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_RESET='\033[0m'

run_async() {
  local label="$1"
  shift
  (
    "$@"
  ) > >(sed "s/^/[${label}] /") 2> >(sed "s/^/[${label}] /" >&2)
}

ensure_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

ensure_inventory_exists() {
  if [[ ! -f ${INVENTORY_FILE} ]]; then
    echo -e "${COLOR_RED}Inventory file not found at ${INVENTORY_FILE}${COLOR_RESET}"
    exit 1
  fi
}

load_inventory() {
  local in_masters=false
  local in_workers=false
  local in_all_vars=false

  SSH_NODES=()
  SSH_MASTER_NODES=()
  SSH_WORKER_NODES=()
  SSH_USERNAME=""
  SSH_USER_PASSWORD=""
  SSH_KEY_PATH=""

  while IFS= read -r line; do
    [[ -z ${line} || ${line} =~ ^[[:space:]]*# ]] && continue

    if [[ ${line} =~ ^\[.*\]$ ]]; then
      case ${line} in
        "[masters]")
          in_masters=true
          in_workers=false
          in_all_vars=false
          ;;
        "[workers]")
          in_masters=false
          in_workers=true
          in_all_vars=false
          ;;
        "[all:vars]")
          in_masters=false
          in_workers=false
          in_all_vars=true
          ;;
        *)
          in_masters=false
          in_workers=false
          in_all_vars=false
          ;;
      esac
      continue
    fi

    if [[ ${in_all_vars} == true && ${line} =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]]; then
      local key value
      key=$(echo "${line}" | cut -d'=' -f1)
      value=$(echo "${line}" | cut -d'=' -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
      case ${key} in
        ansible_user)
          SSH_USERNAME="${value}"
          ;;
        ansible_become_pass)
          SSH_USER_PASSWORD="${value}"
          ;;
        ansible_ssh_private_key_file)
          SSH_KEY_PATH="${value/#\~/${HOME}}"
          ;;
      esac
    fi

    if [[ (${in_masters} == true || ${in_workers} == true) && ${line} =~ ^[a-zA-Z0-9_.-]+ ]]; then
      local hostname ip
      hostname=$(echo "${line}" | awk '{print $1}')
      if [[ ${line} =~ ansible_host=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
        ip="${BASH_REMATCH[1]}"
        SSH_NODES+=("${ip}:${hostname}")
        if [[ ${in_masters} == true ]]; then
          SSH_MASTER_NODES+=("${ip}:${hostname}")
        else
          SSH_WORKER_NODES+=("${ip}:${hostname}")
        fi
      fi
    fi
  done < "${INVENTORY_FILE}"

  if [[ -z ${SSH_USERNAME} || -z ${SSH_USER_PASSWORD} || -z ${SSH_KEY_PATH} ]]; then
    echo -e "${COLOR_RED}Inventory missing required [all:vars] values (ansible_user, ansible_become_pass, ansible_ssh_private_key_file)${COLOR_RESET}"
    exit 1
  fi

  if [[ ${#SSH_NODES[@]} -eq 0 ]]; then
    echo -e "${COLOR_RED}Inventory contains no masters/workers entries with ansible_host${COLOR_RESET}"
    exit 1
  fi
}

ensure_sshpass_installed() {
  if ensure_command sshpass; then
    return
  fi

  echo "Installing sshpass..."
  if ensure_command apt; then
    sudo apt update && sudo apt install -y sshpass
  elif ensure_command yum; then
    sudo yum install -y sshpass
  elif ensure_command dnf; then
    sudo dnf install -y sshpass
  elif ensure_command brew; then
    brew install hudochenkov/sshpass/sshpass || brew install esolitos/ipa/sshpass || brew install sshpass
  else
    echo -e "${COLOR_RED}Unable to install sshpass automatically. Please install it manually.${COLOR_RESET}"
    exit 1
  fi
}

ensure_ansible_installed() {
  if ensure_command ansible-playbook; then
    return
  fi

  echo "Installing Ansible..."
  if ensure_command apt; then
    sudo apt update && sudo apt install -y ansible
  elif ensure_command yum; then
    sudo yum install -y ansible
  elif ensure_command dnf; then
    sudo dnf install -y ansible
  elif ensure_command brew; then
    brew install ansible
  else
    echo -e "${COLOR_RED}Unable to install Ansible automatically. Please install it manually.${COLOR_RESET}"
    exit 1
  fi
}

generate_ssh_key_if_needed() {
  local key_dir
  key_dir=$(dirname "${SSH_KEY_PATH}")
  mkdir -p "${key_dir}"
  if [[ ! -f ${SSH_KEY_PATH} ]]; then
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH}" -N "" -C "admin@$(hostname)"
  fi
}

copy_key_to_root() {
  local node_ip="$1"
  local ssh_target="${SSH_USERNAME}@${node_ip}"
  local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)

  if [[ -z ${SSH_USER_PASSWORD} ]]; then
    echo "    ! ansible_become_pass is required to copy key for root"
    return 1
  fi

  if [[ ! -f ${SSH_KEY_PATH}.pub ]]; then
    echo "    ! Missing public key ${SSH_KEY_PATH}.pub"
    return 1
  fi

  if ! printf '%s\n' "${SSH_USER_PASSWORD}" | sshpass -p "${SSH_USER_PASSWORD}" ssh "${ssh_opts[@]}" "${ssh_target}" \
    "sudo -S bash -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh'" 2>/dev/null; then
    return 1
  fi

  if ! { printf '%s\n' "${SSH_USER_PASSWORD}"; cat "${SSH_KEY_PATH}.pub"; } | sshpass -p "${SSH_USER_PASSWORD}" ssh "${ssh_opts[@]}" "${ssh_target}" \
    "sudo -S tee -a /root/.ssh/authorized_keys >/dev/null" 2>/dev/null; then
    return 1
  fi

  if ! printf '%s\n' "${SSH_USER_PASSWORD}" | sshpass -p "${SSH_USER_PASSWORD}" ssh "${ssh_opts[@]}" "${ssh_target}" \
    "sudo -S chmod 600 /root/.ssh/authorized_keys" 2>/dev/null; then
    return 1
  fi

  return 0
}

setup_single_node() {
  local node_ip="$1"
  local hostname="$2"
 local ssh_target="${SSH_USERNAME}@${node_ip}"
  local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)

  if [[ -n ${hostname} ]]; then
    if ! sshpass -p "${SSH_USER_PASSWORD}" ssh "${ssh_opts[@]}" "${ssh_target}" \
      "echo '${SSH_USER_PASSWORD}' | sudo -S bash -c 'hostnamectl set-hostname ${hostname} && sed -i \"/127.0.1.1/d\" /etc/hosts && echo \"127.0.1.1 ${hostname}\" >> /etc/hosts'" 2>/dev/null; then
      echo "    ! Failed to set hostname"
    fi
  fi

  if ! sshpass -p "${SSH_USER_PASSWORD}" ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${SSH_KEY_PATH}.pub" "${ssh_target}" >/dev/null 2>&1; then
    echo "    ! Failed to copy user key"
    return 1
  fi

  if ! copy_key_to_root "${node_ip}"; then
    echo "    ! Failed to copy root key"
    return 1
  fi

  if ! ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${ssh_target}" "echo ok" >/dev/null 2>&1; then
    echo "    ! User passwordless SSH check failed"
    return 1
  fi

  if ! ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${node_ip}" "echo ok" >/dev/null 2>&1; then
    echo "    ! Root passwordless SSH check failed"
    return 1
  fi

  return 0
}

setup_ssh_for_all_nodes() {
  local -a pids=()
  declare -A node_labels=()

  for entry in "${SSH_NODES[@]}"; do
    IFS=':' read -r node_ip hostname <<< "${entry}"
    [[ -z ${node_ip} ]] && continue
    local label="${hostname:-${node_ip}}"
    run_async "${label}" setup_single_node "${node_ip}" "${hostname}" &
    node_labels[$!]="${label}"
    pids+=($!)
  done

  local failures=0
  for pid in "${pids[@]}"; do
    if ! wait "${pid}"; then
      echo -e "${COLOR_RED}[${node_labels[${pid}]}] SSH setup failed${COLOR_RESET}"
      failures=$((failures + 1))
    fi
  done

  if (( failures > 0 )); then
    echo -e "${COLOR_RED}${failures} node(s) failed SSH setup${COLOR_RESET}"
    exit 1
  fi

  echo -e "${COLOR_GREEN}SSH setup completed for all nodes${COLOR_RESET}"
}

run_playbooks() {
  local playbooks=(
    "01-prepare-packages.yaml"
    "02-node-prereqs.yaml"
    "03-runtime-and-tools.yaml"
    "04-control-plane.yaml"
    "05-workers.yaml"
  )

  export ANSIBLE_HOST_KEY_CHECKING=False

  for pb in "${playbooks[@]}"; do
    local playbook_path="${PLAYBOOK_DIR}/${pb}"
    if [[ ! -f ${playbook_path} ]]; then
      echo -e "${COLOR_RED}Playbook not found: ${playbook_path}${COLOR_RESET}"
      exit 1
    fi
    echo -e "${COLOR_GREEN}Running playbook ${pb}${COLOR_RESET}"
    ansible-playbook -i "${INVENTORY_FILE}" "${playbook_path}"
  done
}

main() {
  ensure_inventory_exists
  load_inventory
  ensure_sshpass_installed
  generate_ssh_key_if_needed
  setup_ssh_for_all_nodes
  ensure_ansible_installed
  run_playbooks
  echo -e "${COLOR_GREEN}Cluster deployment completed successfully.${COLOR_RESET}"
}

main "$@"
