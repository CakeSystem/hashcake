# HashCake v0.1.2

本版本提供 HashCake 服务端 linux-amd64 发布包。

## 更新内容

- 同一代理端口配置多个抽水钱包时，现在可以分别编辑每个钱包的抽水比例；页面会实时显示合计比例并阻止超过 100% 的配置。
- 完善多钱包抽水配置的兼容处理，旧版只提交总比例的管理请求仍可正常使用。
- 更新 Web 管理后台运行依赖，修复已公开的前端依赖安全问题并改善 React 19 兼容性。
- 更新 TLS 证书解析依赖，并加强发布二进制的完整性自检。

## 文件

- hashcake-0.1.2-linux-amd64：HashCake 服务端 linux-amd64 可执行文件，已内嵌 Web 管理后台。

Release 资产只包含二进制文件。安装脚本位于仓库根目录 `install.sh`。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/CakeSystem/hashcake/main/install.sh)
```

首次安装会随机生成 Web 后台端口和安全访问路径，并默认开启自签 HTTPS。

首次登录令牌有效 10 分钟，只用于创建首个管理员账号；账号创建成功后立即失效，之后使用账号与密码登录。

国内服务器可使用下面的通用管理入口。该命令不绑定当前已安装版本；选择安装或更新时，安装器会自动查找官方最新稳定版，并根据 SHA256SUMS 校验下载文件：

```bash
bash <(curl -fsSL https://cdn.jsdmirror.com/gh/CakeSystem/hashcake@fbd28aee583ec8e93aa0bfbb1d211747f392b3ab/install.sh)
```

## 安装器可靠性

- 官方二进制下载会强制核对 `SHA256SUMS`，并在执行前检查实际版本与运行兼容性。
- 首次安装或更新失败会恢复旧二进制、服务文件、配置元数据和防火墙状态，避免留下半安装状态。
- 默认配置位于 `/opt/hashcake/config/hashcake.yaml`；旧路径会在更新时安全迁移。

## 配套项目

- CakeBox：https://github.com/CakeSystem/cakebox
