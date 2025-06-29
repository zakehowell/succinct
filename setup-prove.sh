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
    error_exit "请使用 root 权限运行（例如 sudo ./setup.sh）"
fi

# -------- 检查并安装 Docker --------
if ! command -v docker &> /dev/null; then
    print_message "未检测到 Docker，开始安装 Docker..."

    apt update
    apt install -y apt-transport-https ca-certificates curl software-properties-common

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

    apt update
    apt install -y docker-ce docker-ce-cli containerd.io

    systemctl start docker
    systemctl enable docker

    print_message "Docker 安装完成"
else
    print_message "检测到已安装 Docker，跳过安装"
fi

# -------- 检查并安装 NVIDIA Container Toolkit --------
if ! dpkg -l | grep -q nvidia-container-toolkit; then
    print_message "未检测到 NVIDIA Container Toolkit，开始安装..."

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
    print_message "检测到已安装 NVIDIA Container Toolkit，跳过安装"
fi

# -------- 检查 NVIDIA 驱动版本 --------
check_cuda_version() {
    if ! command -v nvidia-smi &> /dev/null; then
        return 1
    fi
    driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | cut -d. -f1)
    if [ -z "$driver_version" ] || [ "$driver_version" -lt 555 ]; then
        return 1
    fi
    return 0
}

if ! check_cuda_version; then
    print_message "NVIDIA 驱动版本低于 555，建议升级驱动（需 CUDA 12.5+）"
    print_message "请手动安装最新 NVIDIA 驱动，或使用官方 CUDA 安装包"
    error_exit "驱动版本不满足要求，退出脚本"
else
    print_message "NVIDIA 驱动版本符合要求"
fi

# -------- 检测 GPU 数量 --------
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
print_message "检测到 $GPU_COUNT 张 GPU"

# -------- 用户输入 Prover 信息 --------
read -p "请输入你的 Prover 地址（0x 开头40位十六进制）： " PROVER_ADDRESS
read -p "请输入你的私钥（CLI 将使用此私钥，务必保证安全）： " PRIVATE_KEY

# 验证输入
if [[ ! $PROVER_ADDRESS =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    error_exit "Prover 地址格式错误"
fi
if [[ -z "$PRIVATE_KEY" ]]; then
    error_exit "私钥不能为空"
fi

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
      --bid 1.01
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
print_message "全部配置完成！"
echo "使用以下命令启动所有 GPU 实例："
echo "  docker compose up -d"
