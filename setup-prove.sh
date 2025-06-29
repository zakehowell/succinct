#!/bin/bash
set -e

# ===== 辅助函数 =====
print_message() {
    echo -e "\033[1;32m===> $1\033[0m"
}
error_exit() {
    echo -e "\033[1;31m[错误] $1\033[0m" >&2
    exit 1
}

# ===== 权限检查 =====
if [ "$EUID" -ne 0 ]; then
    error_exit "请使用 root 权限运行（例如 sudo ./setup-spn-auto.sh）"
fi

# ===== 安装 Docker =====
if ! command -v docker &>/dev/null; then
    print_message "安装 Docker..."
    apt update
    apt install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io
    systemctl enable --now docker
    print_message "Docker 安装完成"
else
    print_message "已安装 Docker，跳过"
fi

# ===== 安装 NVIDIA Container Toolkit =====
if ! dpkg -l | grep -q nvidia-container-toolkit; then
    print_message "安装 NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
      tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt update
    apt install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    print_message "NVIDIA Container Toolkit 安装完成"
else
    print_message "已安装 NVIDIA Container Toolkit，跳过"
fi

# ===== 检查 NVIDIA 驱动版本 =====
print_message "检查 NVIDIA 驱动版本..."
NEED_DRIVER_UPGRADE=false
if ! command -v nvidia-smi &>/dev/null; then
    NEED_DRIVER_UPGRADE=true
else
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | cut -d. -f1)
    if [[ "$DRIVER_VER" -lt 555 ]]; then
        NEED_DRIVER_UPGRADE=true
    fi
fi

# ===== 自动安装新版驱动（>=555）=====
if $NEED_DRIVER_UPGRADE; then
    print_message "驱动不足，开始安装最新版 NVIDIA 驱动..."
    apt remove --purge -y '^nvidia-.*' || true
    apt autoremove -y || true
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i cuda-keyring_1.1-1_all.deb
    apt update
    apt install -y cuda-drivers
    print_message "驱动安装完成，请重启后重新运行本脚本： sudo reboot"
    exit 0
else
    print_message "驱动版本符合要求"
fi

# ===== 检测 GPU 数量 =====
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
print_message "共检测到 $GPU_COUNT 张 GPU"

# ===== 获取用户输入 =====
read -p "请输入你的 Prover 地址（0x 开头40位）： " PROVER_ADDRESS
read -p "请输入你的私钥（私钥将用于 CLI）： " PRIVATE_KEY
[[ ! $PROVER_ADDRESS =~ ^0x[a-fA-F0-9]{40}$ ]] && error_exit "Prover 地址格式错误"
[[ -z "$PRIVATE_KEY" ]] && error_exit "私钥不能为空"

# ===== 生成 .env =====
cat > .env <<EOF
PROVER_ADDRESS=$PROVER_ADDRESS
PRIVATE_KEY=$PRIVATE_KEY
EOF
print_message "已生成 .env 文件"

# ===== 生成 docker-compose.yml =====
cat > docker-compose.yml <<EOF
version: '3.8'
services:
EOF

for ((i=0; i<GPU_COUNT; i++)); do
cat >> docker-compose.yml <<EOF
  spn-gpu-$i:
    image: public.ecr.aws/succinct-labs/spn-node:latest-gpu
    container_name: spn-gpu-$i
    environment:
      - NETWORK_PRIVATE_KEY=\${PRIVATE_KEY}
    command: >
      prove
      --rpc-url https://rpc.sepolia.succinct.xyz
      --throughput 10485606
      --bid 0.80
      --private-key \${PRIVATE_KEY}
      --prover \${PROVER_ADDRESS}
    runtime: nvidia
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              capabilities: [gpu]
              device_ids: ['$i']
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

EOF
done

print_message "已生成 docker-compose.yml"

echo
print_message "全部配置完成！使用以下命令启动 SPN 多 GPU 节点："
echo "  docker compose up -d"
