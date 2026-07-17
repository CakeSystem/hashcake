# HashCake 定制版 1

## Linux 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/CakeSystem/hashcake/main/customer/1/install.sh)
```

## 国内中转安装（带校验）

下面的命令会固定安装 v0.1.0，并核对定制版二进制的 SHA-256；校验不一致时安装器会拒绝安装：

```bash
HASHCAKE_VERSION=v0.1.0 \
HASHCAKE_DOWNLOAD_URL=https://cdn.jsdmirror.com/gh/CakeSystem/hashcake@main/customer/1/linux-amd64/hashcake-0.1.0-linux-amd64 \
HASHCAKE_DOWNLOAD_SHA256=e7d330698ada677b8b4eeef13a17bb3ad68e674450406daaf473701a23c26f78 \
bash <(curl -fsSL https://cdn.jsdmirror.com/gh/CakeSystem/hashcake@main/customer/1/install.sh)
```

## Windows 下载

```text
https://github.com/CakeSystem/hashcake/releases/latest/download/hashcake-1-windows-amd64.exe
```
