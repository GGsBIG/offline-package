#!/usr/bin/env bash
set -euo pipefail

ROLE=""
CONTROL_PLANE_IP=""
CONTROL_PLANE_HOSTNAME=""
JOIN_COMMAND=""

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PACKAGE_DIR="${SCRIPT_DIR}/k8s-package"

RUN_SSH_SETUP=false
SSH_SETUP_ONLY=false
AUTO_DEPLOY=false
SSH_INVENTORY_FILE="${SCRIPT_DIR}/inventory.ini"
SSH_USERNAME=""
SSH_USER_PASSWORD=""
SSH_ROOT_PASSWORD=""
SSH_KEY_PATH=""
SSH_NODES=()
SSH_MASTER_NODES=()
SSH_WORKER_NODES=()
REMOTE_PACKAGE_DIR="offline-package"

SSH_COLOR_GREEN='\033[0;32m'
SSH_COLOR_RED='\033[0;31m'
SSH_COLOR_RESET='\033[0m'
BLUE='\033[0;34m'
NC='\033[0m'

show_banner() {
    echo -e "${BLUE}"
    echo "██╗  ██╗ █████╗ ███████╗    ██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗"
    echo "██║ ██╔╝██╔══██╗██╔════╝    ██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝"
    echo "█████╔╝ ╚█████╔╝███████╗    ██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝ "
    echo "██╔═██╗ ██╔══██╗╚════██║    ██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝  "
    echo "██║  ██╗╚█████╔╝███████║    ██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║   "
    echo "╚═╝  ╚═╝ ╚════╝ ╚══════╝    ╚═════╝ ╚══════╝╚═╝     ╚══════╝ ╚═════╝    ╚═╝   "
    echo ""
    echo "           Kubernetes 1.34.1 Cluster Deployment (1 Master + 2 Workers)"
    echo "                              Powered by Ansible"
    echo -e "${NC}"
}

show_banner

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}

run_async() {
  local label="$1"
  shift
  (
    "$@"
  ) > >(sed "s/^/[${label}] /") 2> >(sed "s/^/[${label}] /" >&2)
}

ensure_sshpass_installed() {
  if command -v sshpass >/dev/null 2>&1; then
    return
  fi

  echo -e "${SSH_COLOR_RED}Error: sshpass not installed${SSH_COLOR_RESET}"
  echo "Installing sshpass automatically..."

  if command -v apt >/dev/null 2>&1; then
    sudo apt update && sudo apt install -y sshpass
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y sshpass
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y sshpass
  elif command -v brew >/dev/null 2>&1; then
    brew install sshpass
  else
    echo "Please install sshpass manually:"
    echo "  Ubuntu/Debian: sudo apt install sshpass"
    echo "  CentOS/RHEL: sudo yum install sshpass"
    echo "  Fedora: sudo dnf install sshpass"
    echo "  macOS: brew install sshpass"
    exit 1
  fi

  if ! command -v sshpass >/dev/null 2>&1; then
    echo -e "${SSH_COLOR_RED}Failed to install sshpass. Please install manually.${SSH_COLOR_RESET}"
    exit 1
  fi

  echo -e "${SSH_COLOR_GREEN}✓ sshpass installed successfully${SSH_COLOR_RESET}"
}

load_ssh_config() {
  local inventory_file="$1"
  local in_masters_section=false
  local in_workers_section=false
  local in_all_vars_section=false

  SSH_NODES=()
  SSH_MASTER_NODES=()
  SSH_WORKER_NODES=()
  SSH_USERNAME=""
  SSH_USER_PASSWORD=""
  SSH_ROOT_PASSWORD=""
  SSH_KEY_PATH=""

  if [[ ! -f ${inventory_file} ]]; then
    echo -e "${SSH_COLOR_RED}Error: Inventory file '${inventory_file}' not found!${SSH_COLOR_RESET}"
    exit 1
  fi

  echo -e "${SSH_COLOR_GREEN}=== Ultra Simple SSH Setup ===${SSH_COLOR_RESET}"
  echo "Loading configuration from: ${inventory_file}"

  while IFS= read -r line; do
    [[ -z ${line} || ${line} =~ ^[[:space:]]*# ]] && continue

    if [[ ${line} =~ ^\[.*\]$ ]]; then
      if [[ ${line} == "[masters]" ]]; then
        in_masters_section=true
        in_workers_section=false
        in_all_vars_section=false
      elif [[ ${line} == "[workers]" ]]; then
        in_masters_section=false
        in_workers_section=true
        in_all_vars_section=false
      elif [[ ${line} == "[all:vars]" ]]; then
        in_masters_section=false
        in_workers_section=false
        in_all_vars_section=true
      else
        in_masters_section=false
        in_workers_section=false
        in_all_vars_section=false
      fi
      continue
    fi

    if [[ ${in_all_vars_section} == true && ${line} =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]]; then
      local key
      local value
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

    if [[ ${in_masters_section} == true && ${line} =~ ^[a-zA-Z0-9-]+ ]]; then
      local hostname
      hostname=$(echo "${line}" | awk '{print $1}')
      if [[ ${line} =~ ansible_host=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
        local ip
        ip="${BASH_REMATCH[1]}"
        SSH_NODES+=("${ip}:${hostname}")
        SSH_MASTER_NODES+=("${ip}:${hostname}")
      fi
    fi

    if [[ ${in_workers_section} == true && ${line} =~ ^[a-zA-Z0-9-]+ ]]; then
      local hostname
      hostname=$(echo "${line}" | awk '{print $1}')
      if [[ ${line} =~ ansible_host=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
        local ip
        ip="${BASH_REMATCH[1]}"
        SSH_NODES+=("${ip}:${hostname}")
        SSH_WORKER_NODES+=("${ip}:${hostname}")
      fi
    fi
  done < "${inventory_file}"

  if [[ -z ${SSH_USERNAME} || -z ${SSH_USER_PASSWORD} || -z ${SSH_KEY_PATH} ]]; then
    echo -e "${SSH_COLOR_RED}Error: Missing required configuration!${SSH_COLOR_RESET}"
    echo "Required keys (in ${inventory_file} under [all:vars]):"
    echo "  ansible_user"
    echo "  ansible_become_pass"
    echo "  ansible_ssh_private_key_file"
    exit 1
  fi

  SSH_KEY_PATH="${SSH_KEY_PATH/#\~/${HOME}}"
  SSH_ROOT_PASSWORD="${SSH_USER_PASSWORD}"

  if [[ ${#SSH_NODES[@]} -eq 0 ]]; then
    echo -e "${SSH_COLOR_RED}Error: No nodes found in inventory!${SSH_COLOR_RESET}"
    echo "Please define [masters] and [workers] with ansible_host IP values in ${inventory_file}"
    exit 1
  fi

  echo "✓ Configuration loaded"
  echo "  Username: ${SSH_USERNAME}"
  echo "  SSH Key: ${SSH_KEY_PATH}"
  echo "  Nodes: ${#SSH_NODES[@]} found"
}

ensure_hosts_entries_loaded() {
  if [[ ${#SSH_NODES[@]} -gt 0 && -n ${SSH_USERNAME} && -n ${SSH_USER_PASSWORD} && -n ${SSH_KEY_PATH} ]]; then
    return
  fi

  load_ssh_config "${SSH_INVENTORY_FILE}"
}

generate_ssh_key_if_needed() {
  if [[ -z ${SSH_KEY_PATH} ]]; then
    return
  fi

  local key_dir
  key_dir=$(dirname "${SSH_KEY_PATH}")
  mkdir -p "${key_dir}"

  if [[ ! -f ${SSH_KEY_PATH} ]]; then
    echo "Generating SSH key..."
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH}" -N "" -C "admin@$(hostname)"
    echo "✓ SSH key generated"
  else
    echo "✓ SSH key exists"
  fi
}

copy_key_to_root() {
  local node_ip="$1"
  local ssh_target="${SSH_USERNAME}@${node_ip}"
  local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)

  if [[ ! -f ${SSH_KEY_PATH}.pub ]]; then
    echo "    ! Missing public key ${SSH_KEY_PATH}.pub"
    return 1
  fi

  if [[ -z ${SSH_USER_PASSWORD} ]]; then
    echo "    ! ansible_become_pass is required to copy key for root"
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

  echo "----------------------------------------"
  if [[ -n ${hostname} ]]; then
    echo "Setting up: ${node_ip} (hostname: ${hostname})"
  else
    echo "Setting up: ${node_ip}"
  fi

  if [[ -n ${hostname} ]]; then
    echo "  → Setting hostname to: ${hostname}"
    if sshpass -p "${SSH_USER_PASSWORD}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USERNAME}@${node_ip}" "echo '${SSH_USER_PASSWORD}' | sudo -S bash -c 'hostnamectl set-hostname ${hostname} && sed -i \"/127.0.1.1/d\" /etc/hosts && echo \"127.0.1.1 ${hostname}\" >> /etc/hosts'" 2>/dev/null; then
      echo "  ✓ Hostname set successfully"
    else
      echo "  ✗ Hostname setting failed"
    fi
  fi

  echo "  → Copying key to ${SSH_USERNAME}@${node_ip}"
  if ! sshpass -p "${SSH_USER_PASSWORD}" ssh-copy-id -o StrictHostKeyChecking=no -i "${SSH_KEY_PATH}.pub" "${SSH_USERNAME}@${node_ip}" 2>/dev/null; then
    echo "  ✗ User key failed"
    return 1
  fi
  echo "  ✓ User key copied"

  echo "  → Copying key to root@${node_ip}"
  if copy_key_to_root "${node_ip}"; then
    echo "  ✓ Root key copied"
  else
    echo "  ✗ Root key failed"
    return 1
  fi

  echo "  → Testing connections..."
  if ssh -o ConnectTimeout=3 -o BatchMode=yes "${SSH_USERNAME}@${node_ip}" "echo 'User OK'" 2>/dev/null; then
    echo "  ✓ User passwordless login works"
  fi

  if ssh -o ConnectTimeout=3 -o BatchMode=yes "root@${node_ip}" "echo 'Root OK'" 2>/dev/null; then
    echo "  ✓ Root passwordless login works"
  fi

  if [[ -n ${hostname} ]]; then
    local current_hostname
    current_hostname=$(ssh -o ConnectTimeout=3 -o BatchMode=yes "${SSH_USERNAME}@${node_ip}" "hostname" 2>/dev/null || true)
    if [[ ${current_hostname} == "${hostname}" ]]; then
      echo "  ✓ Hostname verified: ${current_hostname}"
    else
      echo "  ! Hostname may need reboot to take effect"
    fi
  fi

  return 0
}

setup_ssh_for_nodes() {
  local -a pids=()
  declare -A node_labels=()
  local first_node_ip=""
  local first_hostname=""

  for node_entry in "${SSH_NODES[@]}"; do
    IFS=':' read -r node_ip hostname <<< "${node_entry}"
    [[ -z ${node_ip} ]] && continue

    if [[ -z ${first_node_ip} ]]; then
      first_node_ip="${node_ip}"
      first_hostname="${hostname}"
    fi

    local label="${hostname:-${node_ip}}"
    run_async "${label}" setup_single_node "${node_ip}" "${hostname}" &
    local pid=$!
    pids+=("${pid}")
    node_labels["${pid}"]="${label}"
  done

  local failures=0
  for pid in "${pids[@]}"; do
    if ! wait "${pid}"; then
      local label="${node_labels["${pid}"]:-${pid}}"
      echo -e "${SSH_COLOR_RED}[${label}] SSH setup failed${SSH_COLOR_RESET}"
      failures=$((failures + 1))
    fi
  done

  if (( failures > 0 )); then
    exit 1
  fi

  echo "----------------------------------------"
  echo -e "${SSH_COLOR_GREEN}Setup completed!${SSH_COLOR_RESET}"
  echo ""
  echo "Test your passwordless login:"
  if [[ -n ${first_node_ip} ]]; then
    if [[ -n ${first_hostname} ]]; then
      echo "  ssh ${SSH_USERNAME}@${first_node_ip}  # ${first_hostname}"
      echo "  ssh root@${first_node_ip}       # ${first_hostname}"
    else
      echo "  ssh ${SSH_USERNAME}@${first_node_ip}"
      echo "  ssh root@${first_node_ip}"
    fi
  fi

  cat <<'EOF'
#                       _oo0oo_
#                      o8888888o
#                      88" . "88
#                      (| -_- |)
#                      0\  =  /0
#                    ___/`---'\___
#                  .' \|     |// '.
#                 / \|||  :  |||// \
#                / _||||| -:- |||||- \
#               |   | \\  -  /// |   |
#               | \_|  ''\---/''  |_/ |
#               \  .-\__  '-'  ___/-. /
#             ___'. .'  /--.--\  `. .'___
#          ."" '<  `.___\_<|>_/___.' >' "".
#         | | :  `- \`.;`\ _ /`.;/ - ` : | |
#         \  \ `_.   \_ __\ /__ _/   .-` /  /
#     =====`-.____`.___ \_____/___.-`___.-'=====
#                       `=---='
#
#
#     ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#               佛祖保佑         永無 BUG
#               佛祖保佑         永不加班
EOF
}

setup_ssh() {
  ensure_sshpass_installed
  load_ssh_config "${SSH_INVENTORY_FILE}"
  generate_ssh_key_if_needed
  setup_ssh_for_nodes
}

ensure_sudo_session() {
  if [[ ${EUID} -eq 0 ]]; then
    return
  fi

  if [[ -z ${SSH_USER_PASSWORD} ]]; then
    sudo -v
    return
  fi

  if ! printf '%s\n' "${SSH_USER_PASSWORD}" | sudo -S -v >/dev/null 2>&1; then
    echo -e "${SSH_COLOR_RED}sudo authentication failed. Check ansible_become_pass in ${SSH_INVENTORY_FILE}.${SSH_COLOR_RESET}"
    exit 1
  fi
}

perform_installation() {
  ensure_hosts_entries_loaded
  ensure_sudo_session
  prepare_packages
  basic_node_setup
  install_containerd
  install_runc
  install_cni_plugins
  install_crictl
  import_images

  if [[ ${ROLE} == "control-plane" ]]; then
    install_kubernetes_control_plane
    configure_kubelet_service
    init_control_plane
    configure_kubectl
    deploy_addons
  else
    install_kubernetes_worker
    configure_kubelet_service
    join_worker
  fi
}

generate_join_command() {
  sudo kubeadm token create --print-join-command --ttl 0
}

sync_offline_package_to_worker() {
  local node_ip="$1"
  local ssh_target="${SSH_USERNAME}@${node_ip}"
  local ssh_opts=(-i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes)

  echo "  → 同步離線套件到 ${node_ip}"
  if ! ssh "${ssh_opts[@]}" "${ssh_target}" "rm -rf ${REMOTE_PACKAGE_DIR} && mkdir -p ${REMOTE_PACKAGE_DIR}"; then
    echo -e "${SSH_COLOR_RED}  ✗ 無法建立遠端目錄${SSH_COLOR_RESET}"
    return 1
  fi

  local files=("offline-install.sh" "k8s-1.tar.zst" "k8s-2.tar.zst" "inventory.ini")
  local file
  for file in "${files[@]}"; do
    local file_path="${SCRIPT_DIR}/${file}"
    if [[ ! -e ${file_path} ]]; then
      echo -e "${SSH_COLOR_RED}  ✗ 缺少檔案 ${file_path}${SSH_COLOR_RESET}"
      return 1
    fi
    if ! scp "${ssh_opts[@]}" "${file_path}" "${ssh_target}:${REMOTE_PACKAGE_DIR}/"; then
      echo -e "${SSH_COLOR_RED}  ✗ 傳送 ${file} 失敗${SSH_COLOR_RESET}"
      return 1
    fi
  done

  ssh "${ssh_opts[@]}" "${ssh_target}" "chmod +x ${REMOTE_PACKAGE_DIR}/offline-install.sh" >/dev/null
}

run_worker_installation() {
  local node_ip="$1"
  local hostname="$2"
  local join_command="$3"
  local ssh_target="${SSH_USERNAME}@${node_ip}"
  local ssh_opts=(-i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes)

  local join_command_quoted
  join_command_quoted=$(shell_quote "${join_command}")
  local remote_cmd="cd ${REMOTE_PACKAGE_DIR} && ./offline-install.sh --role worker --join-command ${join_command_quoted}"
  local remote_cmd_quoted
  remote_cmd_quoted=$(shell_quote "${remote_cmd}")

  echo "  → 安裝 worker 節點 ${hostname:-${node_ip}}"
  if ! ssh "${ssh_opts[@]}" "${ssh_target}" "bash -lc ${remote_cmd_quoted}"; then
    echo -e "${SSH_COLOR_RED}  ✗ 安裝失敗${SSH_COLOR_RESET}"
    return 1
  fi
}

deploy_worker_nodes() {
  local join_command="$1"

  if [[ ${#SSH_WORKER_NODES[@]} -eq 0 ]]; then
    echo "沒有定義 worker 節點，跳過部署"
    return
  fi

  echo "開始部署 worker 節點 (並行 ${#SSH_WORKER_NODES[@]} 台)"
  local -a pids=()
  declare -A worker_labels=()

  local worker_entry
  for worker_entry in "${SSH_WORKER_NODES[@]}"; do
    IFS=':' read -r node_ip hostname <<< "${worker_entry}"
    [[ -z ${node_ip} ]] && continue

    local label="${hostname:-${node_ip}}"
    run_async "${label}" deploy_single_worker "${node_ip}" "${hostname}" "${join_command}" &
    local pid=$!
    pids+=("${pid}")
    worker_labels["${pid}"]="${label}"
  done

  local failures=0
  for pid in "${pids[@]}"; do
    if ! wait "${pid}"; then
      local label="${worker_labels["${pid}"]:-${pid}}"
      echo -e "${SSH_COLOR_RED}[${label}] 佈署失敗${SSH_COLOR_RESET}"
      failures=$((failures + 1))
    fi
  done

  if (( failures > 0 )); then
    echo -e "${SSH_COLOR_RED}${failures} 個 worker 佈署失敗${SSH_COLOR_RESET}"
    exit 1
  fi

  echo -e "${SSH_COLOR_GREEN}所有 worker 佈署完成${SSH_COLOR_RESET}"
}

deploy_single_worker() {
  local node_ip="$1"
  local hostname="$2"
  local join_command="$3"

  echo "----------------------------------------"
  echo "處理 ${hostname:-${node_ip}} (${node_ip})"

  if ! sync_offline_package_to_worker "${node_ip}"; then
    echo -e "${SSH_COLOR_RED}跳過 ${hostname:-${node_ip}}，請手動檢查${SSH_COLOR_RESET}"
    return 1
  fi

  if ! run_worker_installation "${node_ip}" "${hostname}" "${join_command}"; then
    echo -e "${SSH_COLOR_RED}worker ${hostname:-${node_ip}} 安裝失敗${SSH_COLOR_RESET}"
    return 1
  fi

  echo "  ✓ worker ${hostname:-${node_ip}} 完成"
  return 0
}

auto_deploy_cluster() {
  ensure_hosts_entries_loaded

  if [[ ${#SSH_MASTER_NODES[@]} -eq 0 ]]; then
    echo -e "${SSH_COLOR_RED}inventory.ini 未定義 masters 區段，無法自動部署${SSH_COLOR_RESET}"
    exit 1
  fi

  local master_entry="${SSH_MASTER_NODES[0]}"
  IFS=':' read -r master_ip master_hostname <<< "${master_entry}"
  if [[ -z ${master_ip} ]]; then
    echo -e "${SSH_COLOR_RED}masters 設定缺少 ansible_host，無法自動部署${SSH_COLOR_RESET}"
    exit 1
  fi

  if [[ -n ${master_hostname} ]]; then
    CONTROL_PLANE_HOSTNAME="${master_hostname}"
  fi
  CONTROL_PLANE_IP="${master_ip}"
  ROLE="control-plane"

  echo "自動部署控制平面 ${CONTROL_PLANE_HOSTNAME:-master} (${CONTROL_PLANE_IP})"
  perform_installation

  local join_command
  join_command=$(generate_join_command)
  if [[ -z ${join_command} ]]; then
    echo -e "${SSH_COLOR_RED}無法取得 join 指令${SSH_COLOR_RESET}"
    exit 1
  fi

  echo "取得 join 指令: ${join_command}"
  deploy_worker_nodes "${join_command}"
}

usage() {
  cat <<USAGE
Usage: $(basename "$0")
       $(basename "$0") --setup-ssh
       $(basename "$0") --setup-ssh-only
       $(basename "$0") --role control-plane|worker [--control-plane-ip <ip>] [--control-plane-hostname <name>] [--join-command "<command>"]
USAGE
  exit 1
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    AUTO_DEPLOY=true
    RUN_SSH_SETUP=true
    SSH_SETUP_ONLY=false
    return
  fi

  while [[ $# -gt 0 ]]; do
    case $1 in
      --setup-ssh)
        RUN_SSH_SETUP=true
        shift
        ;;
      --setup-ssh-only)
        RUN_SSH_SETUP=true
        SSH_SETUP_ONLY=true
        shift
        ;;
      --role)
        ROLE=${2:-}
        shift 2
        ;;
      --control-plane-ip)
        CONTROL_PLANE_IP=${2:-}
        shift 2
        ;;
      --control-plane-hostname)
        CONTROL_PLANE_HOSTNAME=${2:-}
        shift 2
        ;;
      --join-command)
        JOIN_COMMAND=${2:-}
        shift 2
        ;;
      *)
        usage
        ;;
    esac
  done

  if [[ ${SSH_SETUP_ONLY} == true ]]; then
    return
  fi

  if [[ -z ${ROLE} ]]; then
    usage
  fi

  if [[ ${ROLE} != "control-plane" && ${ROLE} != "worker" ]]; then
    echo "--role must be control-plane or worker" >&2
    exit 1
  fi

  if [[ ${ROLE} == "control-plane" && -z ${CONTROL_PLANE_IP} ]]; then
    echo "--control-plane-ip is required for control-plane role" >&2
    exit 1
  fi

  if [[ ${ROLE} == "worker" && -z ${JOIN_COMMAND} ]]; then
    echo "--join-command is required for worker role" >&2
    exit 1
  fi
}

prepare_packages() {
  local archives=("k8s-1.tar.zst" "k8s-2.tar.zst")
  mkdir -p "${PACKAGE_DIR}"

  for archive in "${archives[@]}"; do
    local archive_path="${SCRIPT_DIR}/${archive}"
    if [[ ! -f ${archive_path} ]]; then
      echo "Missing archive ${archive_path}" >&2
      exit 1
    fi
    tar --zstd -xf "${archive_path}" -C "${SCRIPT_DIR}"
  done

  local src_dirs=("${SCRIPT_DIR}/k8s" "${SCRIPT_DIR}/k8s-2")
  shopt -s dotglob nullglob
  for src in "${src_dirs[@]}"; do
    if [[ -d ${src} ]]; then
      for item in "${src}"/*; do
        mv -f "${item}" "${PACKAGE_DIR}/"
      done
      rmdir "${src}"
    fi
  done
  shopt -u dotglob nullglob
}

basic_node_setup() {
  sudo swapoff -a
  sudo sed -ri 's/(.+ swap .+)/#\1/' /etc/fstab

  cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
overlay
EOF

  sudo modprobe br_netfilter
  sudo modprobe overlay

  cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

  sudo sysctl --system

  ensure_hosts_entries_loaded
  if [[ ${#SSH_NODES[@]} -gt 0 ]]; then
    local hosts_buffer=""
    local entry
    for entry in "${SSH_NODES[@]}"; do
      IFS=':' read -r node_ip hostname <<< "${entry}"
      if [[ -z ${node_ip} || -z ${hostname} ]]; then
        continue
      fi
      hosts_buffer+="${node_ip} ${hostname}\n"
    done

    if [[ -n ${hosts_buffer} ]]; then
      while IFS= read -r host_line; do
        [[ -z ${host_line} ]] && continue
        local host_name
        host_name=$(echo "${host_line}" | awk '{print $2}')
        sudo sed -i "\\| ${host_name}$|d" /etc/hosts
      done <<< "${hosts_buffer}"

      printf '%b' "${hosts_buffer}" | sudo tee -a /etc/hosts >/dev/null
    fi
  fi
}

install_containerd() {
  local archive="${PACKAGE_DIR}/containerd-2.1.3-linux-amd64.tar.gz"
  sudo tar -C /usr/local -xzvf "${archive}"
  sudo mkdir -p /usr/local/lib/systemd/system

  cat <<'EOF' | sudo tee /usr/local/lib/systemd/system/containerd.service >/dev/null
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStart=/usr/local/bin/containerd
Restart=always
RestartSec=5
LimitNOFILE=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now containerd

  sudo mkdir -p /etc/containerd
  sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
  sudo sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml
  sudo sed -i "s|sandbox_image = \"k8s.gcr.io/pause:3.8\"|sandbox_image = \"registry.k8s.io/pause:3.10\"|" /etc/containerd/config.toml
  sudo systemctl daemon-reload && sudo systemctl restart containerd.service
}

install_runc() {
  local binary="${PACKAGE_DIR}/runc.amd64"
  sudo install -m 755 "${binary}" /usr/local/sbin/runc
  runc --version
}

install_cni_plugins() {
  local archive="${PACKAGE_DIR}/cni-plugins.tgz"
  sudo mkdir -p /opt/cni/bin
  sudo tar xf "${archive}" -C /opt/cni/bin
  sudo ls -l /opt/cni/bin
}

install_crictl() {
  local version="v1.33.0"
  local archive="${PACKAGE_DIR}/crictl-${version}-linux-amd64.tar.gz"
  sudo tar -xzf "${archive}" -C /usr/local/bin
  crictl --version

  cat <<'EOF' | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF
}

import_images() {
  local archive="${PACKAGE_DIR}/images.tar.zst"
  tar --zstd -xf "${archive}" -C "${PACKAGE_DIR}"
  sudo ctr -n k8s.io images import "${PACKAGE_DIR}/k8s_images.tar"
  sudo ctr -n k8s.io images ls | grep -E "(v1.33.2|calico|metrics|pause|etcd)"
}

install_kubernetes_control_plane() {
  local archive="${PACKAGE_DIR}/kubernetes-server-linux-amd64.tar.gz"
  sudo tar -xzf "${archive}" -C "${PACKAGE_DIR}"
  sudo cp "${PACKAGE_DIR}/kubernetes/server/bin/kubeadm" /usr/bin/
  sudo cp "${PACKAGE_DIR}/kubernetes/server/bin/kubelet" /usr/bin/
  sudo cp "${PACKAGE_DIR}/kubernetes/server/bin/kubectl" /usr/bin/
  kubeadm version
  kubectl version --client
}

install_kubernetes_worker() {
  local archive="${PACKAGE_DIR}/kubernetes-node-linux-amd64.tar.gz"
  sudo tar -xzf "${archive}" -C "${PACKAGE_DIR}"
  sudo cp "${PACKAGE_DIR}/kubernetes/node/bin/kubeadm" /usr/bin/
  sudo cp "${PACKAGE_DIR}/kubernetes/node/bin/kubelet" /usr/bin/
  kubeadm version
}

configure_kubelet_service() {
  cat <<'EOF' | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  sudo mkdir -p /etc/systemd/system/kubelet.service.d

  cat <<'EOF' | sudo tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
EOF

  sudo systemctl enable kubelet
  sudo systemctl stop kubelet
}

init_control_plane() {
  local config_file="${SCRIPT_DIR}/cluster-config.yaml"
  cat <<EOF > "${config_file}"
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${CONTROL_PLANE_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  name: ${CONTROL_PLANE_HOSTNAME}
  taints: []
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: 1.33.2
clusterName: offline-k8s
controlPlaneEndpoint: ${CONTROL_PLANE_IP}:6443
imageRepository: registry.k8s.io
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/16
  dnsDomain: cluster.local
controllerManager:
  extraArgs:
    bind-address: "0.0.0.0"
    secure-port: "10257"
scheduler:
  extraArgs:
    bind-address: "0.0.0.0"
    secure-port: "10259"
apiServer:
  extraArgs:
    authorization-mode: Node,RBAC
    enable-admission-plugins: NodeRestriction
EOF

  sudo kubeadm init --config "${config_file}" --upload-certs
}

configure_kubectl() {
  mkdir -p "$HOME/.kube"
  sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
  sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
}

deploy_addons() {
  kubectl apply -f "${PACKAGE_DIR}/calico.yaml"
  kubectl -n kube-system get pods -l k8s-app=calico-node
  kubectl apply -f "${PACKAGE_DIR}/components.yaml"
  kubectl -n kube-system get pods -l k8s-app=metrics-server
}

join_worker() {
  eval "${JOIN_COMMAND}"
}

main() {
  parse_args "$@"
  if [[ ${RUN_SSH_SETUP} == true ]]; then
    setup_ssh
    if [[ ${SSH_SETUP_ONLY} == true ]]; then
      return
    fi
  fi

  if [[ ${AUTO_DEPLOY} == true ]]; then
    auto_deploy_cluster
    return
  fi

  if [[ -z ${ROLE} ]]; then
    usage
  fi

  perform_installation
}

main "$@"
