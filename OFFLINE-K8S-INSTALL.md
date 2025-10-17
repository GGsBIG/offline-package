# 離線安裝 Kubernetes 1.33.2 操作手冊
## 2. 節點基本設定（所有節點）

1. **停用 SWAP**（確保開機後仍為關閉）：

```bash
sudo swapoff -a
sudo sed -ri 's/(.+ swap .+)/#\1/' /etc/fstab
```

2. **載入核心模組**：

```bash
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
overlay
EOF

sudo modprobe br_netfilter
sudo modprobe overlay
```

3. **調整網路參數**：

```bash
cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

4. **設定 `/etc/hosts`（若無內部 DNS）**：於三台節點皆新增：

```bash
cat <<'EOF' | sudo tee -a /etc/hosts
10.8.57.223 k8s-starlux-m1
10.8.57.224 k8s-starlux-w1
10.8.57.28 k8s-starlux-w2
EOF
```

---

## 3. 安裝 containerd、runc、CNI、crictl（所有節點）

### 3.1 安裝 containerd 2.1.3

```bash
sudo tar Cxzvf /usr/local containerd-2.1.3-linux-amd64.tar.gz
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

sudo systemctl status containerd.service
```

範例輸出：

```text
● containerd.service - containerd container runtime
     Loaded: loaded (/usr/local/lib/systemd/system/containerd.service; enabled; preset: enabled)
     Active: active (running) since Tue 2025-06-10 06:17:14 UTC; 9s ago
       Docs: https://containerd.io
    Process: 1162 ExecStartPre=/sbin/modprobe overlay (code=exited, status=0/SUCCESS)
```

產生預設設定檔：

```bash
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
```

修改設定：

```bash
sudo sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml
sudo sed -i "s|sandbox_image = "k8s.gcr.io/pause:3.8"|sandbox_image = "registry.k8s.io/pause:3.10"|" /etc/containerd/config.toml
```

套用設定後重新載入並確認狀態：

```bash
sudo systemctl daemon-reload && sudo systemctl restart containerd.service
sudo systemctl status containerd.service
```


### 3.2 安裝 runc 1.3.0

```bash
sudo install -m 755 runc.amd64 /usr/local/sbin/runc
runc --version
```

### 3.3 安裝 CNI plugins

```bash
sudo mkdir -p /opt/cni/bin
sudo tar xf cni-plugins.tgz -C /opt/cni/bin
sudo ls -l /opt/cni/bin
```

### 3.4 安裝 crictl

```bash
CRICTL_VERSION=v1.33.0
sudo tar -xzf crictl-${CRICTL_VERSION}-linux-amd64.tar.gz -C /usr/local/bin
crictl --version
```

### 3.5 設定 crictl 預設端點

```bash
cat <<'EOF' | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF
```

---

## 4. 匯入 Kubernetes 與 Calico 映像（所有節點）

1. 解開映像包：

```bash
tar --zstd -xf images.tar.zst
```

2. 匯入到 containerd：

```bash
sudo ctr -n k8s.io images import k8s_images.tar
sudo ctr -n k8s.io images ls | grep -E "(v1.33.2|calico|metrics|pause|etcd)"
```

## 5. 安裝 Kubernetes 指令與 kubelet 服務

### 5.1 控制平面（k8s-starlux-m1）

```bash
sudo tar -xzf kubernetes-server-linux-amd64.tar.gz
sudo cp kubernetes/server/bin/kubeadm /usr/bin/
sudo cp kubernetes/server/bin/kubelet /usr/bin/
sudo cp kubernetes/server/bin/kubectl /usr/bin/
kubeadm version
kubectl version --client
```

### 5.2 工作節點（k8s-starlux-w1、k8s-starlux-w2）

```bash
sudo tar -xzf kubernetes-node-linux-amd64.tar.gz
sudo cp kubernetes/node/bin/kubeadm /usr/bin/
sudo cp kubernetes/node/bin/kubelet /usr/bin/
kubeadm version
```

> 若工作節點需要操作 `kubectl`，可從 k8s-starlux-m1 複製 `/usr/bin/kubectl` 與 `/etc/kubernetes/admin.conf`。

### 5.3 建立 kubelet systemd 服務（所有節點）

```bash
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
```

---

## 6. 控制平面初始化（僅 k8s-starlux-m1 ）

### 6.1 建立 kubeadm 設定檔

在撰寫設定檔前，請以 `ip addr show` 核對目前節點實際擁有的 IP，以下範例中的 `10.8.57.223` 請改成 **k8s-starlux-m1 的實際 IP**，否則 etcd 將出現 `bind: cannot assign requested address` 而無法啟動。

```bash
cat <<'EOF' > cluster-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.8.57.223
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  name: k8s-starlux-m1
  taints: []
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: 1.33.2
clusterName: offline-k8s
controlPlaneEndpoint: 10.8.57.223:6443
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
```

> 所有映像已事先載入，不會再連線外部 Registry。

### 6.2 執行初始化

```bash
sudo kubeadm init --config cluster-config.yaml --upload-certs
```

完成後請記錄輸出的 `kubeadm join ...` 指令與 `--certificate-key`，供工作節點與未來額外控制平面使用。

### 6.3 配置管理者憑證

```bash
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown $(id -u):$(id -g) "$HOME/.kube/config"
```

---

## 7. 部署 Calico 與 metrics-server（於 k8s-starlux-m1 ）

### 7.1 安裝 Calico CNI

```bash
kubectl apply -f calico.yaml
kubectl -n kube-system get pods -l k8s-app=calico-node
```

### 7.2 安裝 metrics-server

`components.yaml` 已內建 `--kubelet-insecure-tls` 參數，可直接套用。

```bash
kubectl apply -f components.yaml
kubectl -n kube-system get pods -l k8s-app=metrics-server
```

---

## 8. 加入工作節點（於 k8s-starlux-w1 / k8s-starlux-w2 ）

在每個工作節點上執行於 k8s-starlux-m1 初始化時產生的 `kubeadm join` 指令，例如：

```bash
sudo kubeadm join 10.8.57.223:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

加入完成後，回到 k8s-starlux-m1 驗證：

```bash
kubectl get nodes -o wide
```

若忘記 `join` 內容，可在 k8s-starlux-m1 重新產生：

```bash
sudo kubeadm token create --print-join-command
```
