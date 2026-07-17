# HashCake v0.1.0

本版本提供 HashCake 服务端 linux-amd64 发布包。

## 文件

- hashcake-0.1.0-linux-amd64：HashCake 服务端 linux-amd64 可执行文件，已内嵌 Web 管理后台。

Release 资产只包含二进制文件。安装脚本位于仓库根目录 `install.sh`。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/CakeSystem/hashcake/main/install.sh)
```

首次安装会随机生成 Web 后台端口和安全访问路径，并默认开启自签 HTTPS。

首次登录令牌有效 10 分钟，只用于创建首个管理员账号；账号创建成功后立即失效，之后使用账号与密码登录。

国内服务器可使用带二进制 SHA-256 校验的中转命令：

```bash
HASHCAKE_VERSION=v0.1.0 \
HASHCAKE_DOWNLOAD_URL=https://cdn.jsdmirror.com/gh/CakeSystem/hashcake@d42a9ccfcdefe3b1557495efcc2d5c412f1c242f/linux-amd64/hashcake-0.1.0-linux-amd64 \
HASHCAKE_DOWNLOAD_SHA256=f3b9fe5489f581dabdbecc23348b63a5970f2d5a0dd17fa82b5f7be910595c95 \
bash <(curl -fsSL https://cdn.jsdmirror.com/gh/CakeSystem/hashcake@d42a9ccfcdefe3b1557495efcc2d5c412f1c242f/install.sh)
```

## 安装器可靠性

- 官方二进制下载会强制核对 `SHA256SUMS`，并在执行前检查实际版本与运行兼容性。
- 首次安装或更新失败会恢复旧二进制、服务文件、配置元数据和防火墙状态，避免留下半安装状态。
- 默认配置位于 `/opt/hashcake/config/hashcake.yaml`；旧路径会在更新时安全迁移。

## 配套项目

- CakeBox：https://github.com/CakeSystem/cakebox
