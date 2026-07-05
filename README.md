# HashCake

HashCake 是服务端 Stratum 代理，部署在矿机和上游矿池之间。它负责统一接入矿机、连接主矿池和费用矿池，并通过管理后台观察端口、矿机、上游连接、CakeBox 隧道和运行指标。

## 配套项目

- CakeBox 客户端：https://github.com/CakeSystem/cakebox
- CakeHub 管理服务：https://github.com/HsMirage/HashCake

## 一键安装

在 Linux amd64 服务器上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/CakeSystem/hashcake/main/install.sh)
```

如果服务器不能使用 `bash <(...)`，也可以分两步：

```bash
curl -fsSL https://raw.githubusercontent.com/CakeSystem/hashcake/main/install.sh -o install-hashcake.sh
sudo bash install-hashcake.sh
```

## Windows 下载

Windows amd64 版本可在 Release 页面下载：

```text
https://github.com/CakeSystem/hashcake/releases/download/v0.1.0/hashcake-0.1.0-windows-amd64.exe
```

## 默认路径

- 安装目录：`/opt/hashcake`
- 配置文件：`/opt/hashcake/hashcake.yaml`
- 状态目录：`/opt/hashcake/state`
- 日志目录：`/opt/hashcake/logs`
- systemd 服务名：`hashcake`
- 管理后台监听：`0.0.0.0:8088`

## 环境变量

- `HASHCAKE_VERSION=v0.1.0`：安装指定版本，默认从 `linux-amd64/` 文件夹选择最新版本。
- `HASHCAKE_RELEASE_BRANCH=main`：读取发布文件的 Git 分支。
- `HASHCAKE_HOME=/opt/hashcake`：安装目录。
- `HASHCAKE_DOWNLOAD_URL=https://...`：从指定地址下载二进制。

## 发布文件

- `linux-amd64/hashcake-0.1.0-linux-amd64`：Linux amd64 可执行文件，已内嵌 Web 管理后台。
- `install.sh`：仓库根目录的一键安装和管理脚本。
- Release 资产：只上传二进制文件，例如 `hashcake-0.1.0-linux-amd64`。
- `SHA256SUMS`：本地发布文件校验和，路径按本地发布目录记录。
