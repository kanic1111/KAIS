#!/bin/bash
# Disk and mount point
DISK="/dev/vdb"
MOUNTPOINT="/mnt"

# Check if disk exists
if [ ! -b "$DISK" ]; then
    echo "Disk $DISK does not exist!"
    exit 1
fi

# Check if disk is formatted
FS_TYPE=$(blkid -o value -s TYPE "$DISK")
if [ -z "$FS_TYPE" ]; then
    echo "Formatting $DISK as ext4..."
    sudo mkfs.ext4 -F "$DISK"
else
    echo "$DISK is already formatted as $FS_TYPE"
fi

# Create mount point if not exists
if [ ! -d "$MOUNTPOINT" ]; then
    echo "Creating mount point $MOUNTPOINT..."
    sudo mkdir -p "$MOUNTPOINT"
fi

# Mount the disk
echo "Mounting $DISK to $MOUNTPOINT..."
sudo mount "$DISK" "$MOUNTPOINT"

# Add to /etc/fstab if not already present
UUID=$(blkid -s UUID -o value "$DISK")
if ! grep -q "$UUID" /etc/fstab; then
    echo "Adding $DISK to /etc/fstab..."
    echo "UUID=$UUID  $MOUNTPOINT  ext4  defaults  0 2" | sudo tee -a /etc/fstab
else
    echo "$DISK is already in /etc/fstab"
fi

echo "Mount disk Complete change containerd mountpoint to mount disk "

ROOT_DEV=$(findmnt -n -o SOURCE / | sed -E 's|/dev/||; s/[0-9]+$//')
MNT=$(lsblk -nr -o NAME,MOUNTPOINT | awk -v root="$ROOT_DEV" '$2 != "" && $1 !~ "^"root {print $1; exit}')
MNT_PATH=$(findmnt -n -o TARGET /dev/$MNT)

sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

# Install Docker From Docker Official
curl -Ol https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/amd64/containerd.io_1.7.25-1_amd64.deb
curl -Ol https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/amd64/docker-ce_27.5.1-1~ubuntu.22.04~jammy_amd64.deb
curl -Ol https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/amd64/docker-ce-rootless-extras_27.5.1-1~ubuntu.22.04~jammy_amd64.deb
curl -Ol https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/amd64/docker-ce-cli_27.5.1-1~ubuntu.22.04~jammy_amd64.deb

sudo dpkg -i *.deb
rm *.deb
sudo usermod -aG docker $USER
sudo systemctl start docker
sudo systemctl enable docker
sudo docker version

sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml
root = "/home/ubuntu/nemo-workspace/containerd"
state = "/home/ubuntu/nemo-workspace/containerd"
sudo sed -i -e "s|^\(root\s*=\s*\).*|\1\"$MNT_PATH/containerd/root\"|" /etc/containerd/config.toml
sudo sed -i -e "s|^\(state\s*=\s*\).*|\1\"$MNT_PATH/containerd/state\"|" /etc/containerd/config.toml
sudo sed -i "s/SystemdCgroup = false/SystemdCgroup = true/g" /etc/containerd/config.toml
grep SystemdCgroup /etc/containerd/config.toml
sudo systemctl restart containerd

# change docker cgroup driver to systemd
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

sudo mkdir -p /etc/systemd/system/docker.service.d
sudo systemctl daemon-reload
sudo systemctl restart docker
systemctl status --no-pager docker


curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update

# Essential Tweaks
sudo swapoff -a
cat << EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# insall k8s
#version=1.28.0-00
#echo $version
#apt-cache show kubectl | grep "Version: $version"
#sudo apt install -y kubelet=$version kubectl=$version kubeadm=$version
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

sudo kubeadm init --service-cidr=10.96.0.0/12 --pod-network-cidr=10.244.0.0/16 --v=6

mkdir -p $HOME/.kube
# Copy the kubeconfig file to the .kube directory
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
# Change ownership of the kubeconfig file to your user
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl taint node --all node-role.kubernetes.io/control-plane:NoSchedule-

# set up autocomplete in bash into the current shell, bash-completion package should be installed first.
source <(kubectl completion bash) 
echo "source <(kubectl completion bash)" >> ~/.bashrc 
sudo crictl config runtime-endpoint unix:///var/run/containerd/containerd.sock
# Install cillum-cli
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

# install cillum with cni-exclusive OFF
cilium install --version 1.16.5 --set cni.exclusive=false
