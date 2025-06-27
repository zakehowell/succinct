# ⚡️ Succinct Prover 一键部署脚本

本项目提供了一套自动化部署脚本，用于在支持 GPU 的 Ubuntu VPS 上快速部署 [Succinct Prover](https://docs.succinct.xyz/) 节点。

无需手动配置环境、安装依赖、拉取镜像、运行校准、编辑 `.env`，只需一条命令，部署全流程自动完成 ✅

---

## 🚀 一键运行节点（推荐）

使用以下命令，即可在支持 NVIDIA GPU 的 Ubuntu 22.04 VPS 上完成完整部署：

```bash
# 更新依赖 安装wget
apt update && apt install -y wget

# 一键启动
bash <(wget -qO- https://raw.githubusercontent.com/zakehowell/succinct/main/setup.sh)
```

## ✅ 部署自动执行以下操作：
安装系统依赖（build-essential、Docker 等）

安装 & 配置 Docker + NVIDIA Container Toolkit

检查 GPU 驱动是否满足 CUDA 12.5 要求（驱动版本 >= 555）

自动修复驱动（如版本不符）

拉取 Succinct 官方 spn-node:latest-gpu 镜像

运行 calibrate 自动校准节点性能

提示填写：

PRIVATE_KEY

PGUS_PER_SECOND

PROVE_PER_BPGU

PROVER_ADDRESS

自动生成 .env 和 docker-compose.yml

启动 Prover 节点容器

## 🧪 示例校准输出参考
校准完成后将输出：

```bash
Calibration Results:
Estimated Throughput │ 1742469 PGUs/second
Estimated Bid Price  │ 0.28 $PROVE per 1B PGUs
```

你可填入：

```bash
PGUS_PER_SECOND=1742469
PROVE_PER_BPGU=0.28
```

脚本会自动将这些信息写入 .env 中。

## 🐳 容器命令说明

```bash
## 启动节点：
docker compose up -d
```

```bash
## 查看实时日志：
docker compose logs -f
```

```bash
## 查看最近日志：
docker compose logs -fn 100
```

```bash
## 停止节点：
docker stop succinct-spn-node
docker rm succinct-spn-node
```