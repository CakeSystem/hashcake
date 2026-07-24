# HashCake 定制版 1

## Linux 安装与管理

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/CakeSystem/hashcake/main/customer/1/install.sh) menu
```

## 国内中转（安装、更新与管理，带校验）

下面的命令会打开 HashCake 一键安装管理菜单，可用于首次安装、更新程序和日常管理。需要下载二进制时会使用当前发布版 v0.1.1，并核对 SHA-256；校验不一致时安装器会拒绝继续：

```bash
HASHCAKE_VERSION=v0.1.1 \
HASHCAKE_DOWNLOAD_URL=https://cdn.jsdmirror.com/gh/CakeSystem/hashcake@2b190e40eb529ae7fb1b5d67ff34c5d906a5a35e/customer/1/linux-amd64/hashcake-0.1.1-linux-amd64 \
HASHCAKE_DOWNLOAD_SHA256=c2594cff3b883181a121f6b591edbd004be6d36d9851b3568c31e8b0dc71f365 \
bash <(curl -fsSL https://cdn.jsdmirror.com/gh/CakeSystem/hashcake@2b190e40eb529ae7fb1b5d67ff34c5d906a5a35e/customer/1/install.sh) menu
```

## Windows 下载

```text
https://github.com/CakeSystem/hashcake/releases/latest/download/hashcake-1-windows-amd64.exe
```
