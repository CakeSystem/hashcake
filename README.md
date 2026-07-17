# HashCake

HashCake 是服务端 Stratum 代理，部署在矿机和上游矿池之间。它负责统一接入矿机、连接主矿池和费用矿池，并通过管理后台观察端口、矿机、上游连接、CakeBox 隧道和运行指标。

## 配套项目

- CakeBox 客户端：https://github.com/CakeSystem/cakebox

## 首次安装

在 Linux amd64 服务器上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/CakeSystem/hashcake/main/install.sh) install
```

如果服务器不能使用 `bash <(...)`，也可以分两步：

```bash
curl -fsSL https://raw.githubusercontent.com/CakeSystem/hashcake/main/install.sh -o install-hashcake.sh
sudo bash install-hashcake.sh install
```

运行要求：Linux amd64、bash 4 或更高版本、systemd 247 或更高版本，并使用 root 权限。安装器会在修改系统前检查这些条件；二进制不兼容时会保留并显示原始错误。

首次登录令牌有效 10 分钟，只用于创建首个管理员账号；账号创建成功后立即失效，之后使用账号与密码登录。

## 国内中转安装（带校验）

无法稳定访问 GitHub 的服务器使用下面的命令。安装器会核对下载二进制的 SHA-256，不一致时会拒绝安装：

```bash
HASHCAKE_VERSION=v0.1.0 \
HASHCAKE_DOWNLOAD_URL=https://cdn.jsdmirror.com/gh/CakeSystem/hashcake@main/linux-amd64/hashcake-0.1.0-linux-amd64 \
HASHCAKE_DOWNLOAD_SHA256=f3b9fe5489f581dabdbecc23348b63a5970f2d5a0dd17fa82b5f7be910595c95 \
bash <(curl -fsSL https://cdn.jsdmirror.com/gh/CakeSystem/hashcake@main/install.sh) install
```

## 更新程序

```bash
sudo bash install-hashcake.sh update
```

更新会保留已有 Web 端口、安全访问路径、账号、令牌、配置和状态目录。新版本启动失败时，安装器会自动恢复旧二进制、旧服务文件和原有防火墙状态。

## Windows 下载

Windows amd64 版本可在 Release 页面下载：

```text
https://github.com/CakeSystem/hashcake/releases/download/v0.1.0/hashcake-0.1.0-windows.exe
```

## 默认路径

- 安装目录：`/opt/hashcake`
- 配置文件：`/opt/hashcake/config/hashcake.yaml`
- 状态目录：`/opt/hashcake/state`
- 日志目录：`/opt/hashcake/logs`
- systemd 服务名：`hashcake`
- 管理后台监听：首次安装时在 `10000-60000` 内随机生成，默认绑定 `0.0.0.0`
- 安全访问路径：首次安装时随机生成，例如 `/hc-a8f3k9m2/`
- HTTPS：默认开启自签 HTTPS，不申请证书

## 环境变量

- `HASHCAKE_VERSION=v0.1.0`：安装指定版本，默认从 `linux-amd64/` 文件夹选择最新版本。
- `HASHCAKE_ALLOW_PRERELEASE=1`：允许 `latest` 选择预发布版本；默认只选择稳定版。
- `HASHCAKE_RELEASE_BRANCH=main`：读取发布文件的 Git 分支。
- `HASHCAKE_HOME=/opt/hashcake`：安装目录。
- `HASHCAKE_CONFIG_DIR=/opt/hashcake/config`：配置目录；必须允许 `hashcake` 服务用户原子保存配置。
- `HASHCAKE_DOWNLOAD_URL=https://...`：从指定地址下载二进制。
- `HASHCAKE_DOWNLOAD_SHA256=64位十六进制`：校验自定义下载地址；官方仓库下载会自动使用 `SHA256SUMS` 校验。
- `HASHCAKE_ADMIN_BIND=0.0.0.0:12345`：首次安装或修改 Web 设置时指定后台监听地址。
- `HASHCAKE_URL_PREFIX=mirage`：首次安装或修改 Web 设置时指定安全访问路径。

## 发布文件

- `linux-amd64/hashcake-0.1.0-linux-amd64`：linux-amd64 可执行文件，已内嵌 Web 管理后台。
- `install.sh`：仓库根目录的一键安装和管理脚本。
- Release 资产：上传二进制文件，例如 `hashcake-0.1.0-linux-amd64`。
- `SHA256SUMS`：公开发布文件校验和；安装器下载官方二进制前会强制核对。
