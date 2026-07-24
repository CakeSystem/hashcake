# HashCake 定制版 1

## Linux 安装与管理

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/CakeSystem/hashcake/main/customer/1/install.sh) menu
```

## 国内中转（安装、更新与管理，带校验）

下面的命令会打开 HashCake 一键安装管理菜单，不绑定当前已安装版本。选择首次安装或更新时，安装器会自动查找 Edition 1 的最新稳定版，并根据该 Edition 的 SHA256SUMS 校验下载文件；日常管理操作不会重新安装程序：

```bash
bash <(curl -fsSL https://cdn.jsdmirror.com/gh/CakeSystem/hashcake@2b190e40eb529ae7fb1b5d67ff34c5d906a5a35e/customer/1/install.sh) menu
```

## Windows 下载

```text
https://github.com/CakeSystem/hashcake/releases/latest/download/hashcake-1-windows-amd64.exe
```
