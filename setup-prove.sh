#!/bin/bash
set -e

# -------- 辅助函数 --------
print_message() {
    echo -e "\033[1;32m===> $1\033[0m"
}

error_exit() {
    echo -e "\033[1;31m[错误] $1\033[0m" >&2
    exit 1
}

# -------- 权限检查 --------
if [ "$EUID" -ne 0 ]; then
    error_exit "请使用 root 权限运行（例如 sudo ./setup-spn.sh）"
fi

# -------- 安装 Docker --------
if ! command -v docker &>/dev/null; then
    print_message "安装 Docker..."
    apt update
    apt install -y apt-transport-https ca-certificates curl software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io
    systemctl enable docker --now
    print_message "Docker 安装完成"
else
    print_message "已安装 Docker，跳过"
fi

# -------- 安装 NVIDIA Container Toolkit --------
if ! dpkg -l | grep -q nvidia-container-toolkit; then
    print_message "安装 NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt update
    apt install -y nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    print_message "NVIDIA Container Toolkit 安装完成"
else
    print_message "已安装 NVIDIA Container Toolkit，跳过"
fi

# -------- 检查 NVIDIA 驱动版本 --------
check_driver() {
    if ! command -v nvidia-smi &>/dev/null; then return 1; fi
    driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | cut -d. -f1)
    [[ "$driver_version" -ge 555 ]]
}

if check_driver; then
    print_message "NVIDIA 驱动版本符合要求 (>=555)"
else
    error_exit "驱动版本不足，请手动安装 >= 555 版本驱动（支持 CUDA 12.5）后重试"
fi

# -------- 检测 GPU 数量 --------
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
print_message "共检测到 $GPU_COUNT 张 GPU"

# -------- 获取用户输入 --------
read -p "请输入你的 Prover 地址（0x 开头40位）： " PROVER_ADDRESS
read -p "请输入你的私钥（私钥将用于 CLI）： " PRIVATE_KEY

[[ ! $PROVER_ADDRESS =~ ^0x[a-fA-F0-9]{40}$ ]] && error_exit "Prover 地址格式错误"
[[ -z "$PRIVATE_KEY" ]] && error_exit "私钥不能为空"

# -------- 生成 .env 文件 --------
cat > .env <<EOF
PROVER_ADDRESS=$PROVER_ADDRESS
PRIVATE_KEY=$PRIVATE_KEY
EOF
print_message "已生成 .env 文件"

# -------- 生成 docker-compose.yml --------
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
      --bid 0.5
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
      limits:
      cpus: '12.0'  # ← 如需限制每个容器最大 CPU 使用数，可取消注释并修改
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

EOF
done

print_message "已生成 docker-compose.yml"

echo
print_message "全部配置完成！使用以下命令启动："
echo "  docker compose up -d"
