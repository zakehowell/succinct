#!/bin/bash
set -e

print_message() {
    echo -e "\n===> $1\n"
}

check_status() {
    if [ $? -eq 0 ]; then
        print_message "\xe2\x9c\x85 $1 成功"
    else
        print_message "\xe2\x9d\x8c $1 失败"
        exit 1
    fi
}

if [ "$EUID" -ne 0 ]; then 
    print_message "\xf0\x9f\x9a\xa7 请使用 sudo 运行脚本"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
print_message "\xf0\x9f\x93\xa6 安装系统依赖包..."
apt update && apt upgrade -y
apt install -y curl gnupg ca-certificates build-essential git wget nano lz4 jq make gcc automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev tar clang unzip libleveldb-dev libclang-dev ninja-build software-properties-common
check_status "依赖安装"

if ! command -v docker &> /dev/null; then
    print_message "\xf0\x9f\x9b\xb2 安装 Docker..."
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do apt remove -y $pkg || true; done
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl start docker && systemctl enable docker
    print_message "Docker 安装完成"
fi

if ! dpkg -l | grep -q nvidia-container-toolkit; then
    print_message "\xf0\x9f\x9a\xa7 安装 NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt update
    apt install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    check_status "NVIDIA 容器运行时配置"
fi

check_cuda_version() {
    if ! command -v nvidia-smi &> /dev/null; then
        print_message "未检测到 nvidia-smi"
        return 1
    fi
    driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | cut -d. -f1)
    if [ -z "$driver_version" ] || [ "$driver_version" -lt 555 ]; then
        return 1
    fi
    return 0
}

if ! check_cuda_version; then
    print_message "\xf0\x9f\x9a\xa7 安装 NVIDIA 驱动以支持 CUDA 12.5+..."
    apt remove -y nvidia-* --purge || true
    apt autoremove -y
    curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb -O
    dpkg -i cuda-keyring_1.1-1_all.deb
    apt update
    apt install -y cuda-drivers
    print_message "\xf0\x9f\x9f\xa2 NVIDIA 驱动安装完成，请重启后重新运行此脚本"
    exit 0
fi

print_message "\xf0\x9f\x9b\xa0 拉取 Succinct Prover 镜像..."
docker pull public.ecr.aws/succinct-labs/spn-node:latest-gpu
check_status "镜像拉取"

GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
print_message "\xf0\x9f\x96\xa5\xef\xb8\x8f GPU 检测：$GPU_COUNT x $GPU_MODEL"

read -p "请输入 PRIVATE_KEY（不会存储，仅用于 calibrate）：" PRIVATE_KEY
if [ -z "$PRIVATE_KEY" ]; then
    print_message "PRIVATE_KEY 不能为空"
    exit 1
fi

print_message "\xe2\x9a\x99\xef\xb8\x8f 执行硬件性能校准..."
docker run --rm --gpus all \
    --device-cgroup-rule='c 195:* rmw' \
    --network host \
    -e NETWORK_PRIVATE_KEY="$PRIVATE_KEY" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    public.ecr.aws/succinct-labs/spn-node:latest-gpu \
    calibrate \
    --usd-cost-per-hour 0.80 \
    --utilization-rate 0.5 \
    --profit-margin 0.1 \
    --prove-price 1.00

read -p "请输入 PGUS_PER_SECOND（参考上方校准结果）：" PGUS_PER_SECOND
read -p "请输入 PROVE_PER_BPGU（建议 0.28 或 1.01）：" PROVE_PER_BPGU
read -p "请输入您的 Prover 地址（0x...）：" PROVER_ADDRESS

cat <<EOF > .env
export PRIVATE_KEY=$PRIVATE_KEY
export PGUS_PER_SECOND=$PGUS_PER_SECOND
export PROVE_PER_BPGU=$PROVE_PER_BPGU
export PROVER_ADDRESS=$PROVER_ADDRESS
export RPC_URL=https://rpc.sepolia.succinct.xyz
EOF

cat <<EOF > docker-compose.yml
version: "3.8"
services:
  succinct-spn-node:
    image: public.ecr.aws/succinct-labs/spn-node:latest-gpu
    container_name: succinct-spn-node
    restart: always
    network_mode: host
    environment:
      - PRIVATE_KEY=\${PRIVATE_KEY}
      - PGUS_PER_SECOND=\${PGUS_PER_SECOND}
      - PROVE_PER_BPGU=\${PROVE_PER_BPGU}
      - PROVER_ADDRESS=\${PROVER_ADDRESS}
      - RPC_URL=\${RPC_URL}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: [gpu]
    command: >
      prove
      --rpc-url \${RPC_URL}
      --throughput \${PGUS_PER_SECOND}
      --bid \${PROVE_PER_BPGU}
      --private-key \${PRIVATE_KEY}
      --prover \${PROVER_ADDRESS}
EOF


print_message "\xf0\x9f\x9a\x80 启动 Prover 节点..."
docker compose up -d
check_status "Succinct Prover 节点已启动"

print_message "\xf0\x9f\x8e\x89 部署完成！使用 'docker compose logs -f' 查看日志"
