# OpenClaw 一键部署脚本（Debian 12）

在全新的 Debian 12 服务器上一键部署 [OpenClaw](https://github.com/openclaw/openclaw)：系统依赖、Swap、Node.js 24、OpenClaw 本体、systemd 服务，外加一个交互式管理工具 `openclaw-manage`——装完之后改模型、换 Key、管白名单，全程不用手编 JSON。

## 一行安装

```bash
curl -fsSL https://raw.githubusercontent.com/zhouzijie286-star/openclaw-installer/main/install-openclaw.sh | bash
```

> 需要 root 权限与 SSH 交互终端；脚本会在需要时询问配置。

## 它做什么

- **系统依赖**：ca-certificates / curl / git / python3 / build-essential
- **Swap**：内存不足 1GB 时引导创建 4G Swap（可拒绝；写 fstab 持久化）
- **Node.js**：安装 Node 24（已装高版本则复用，规避 nvm 与 systemd 的路径冲突）
- **OpenClaw**：npm 全局安装最新版，固定于 /usr/local
- **systemd 服务**：openclaw.service 开机自启、崩溃自动拉起
- **管理工具**：`openclaw-manage` 交互菜单

安装过程中的交互式初始化：

- 模型 API 配置（支持 OpenAI Chat Completions / OpenAI Responses / Anthropic Messages 三种协议）
- 可注册多个模型并选择默认
- Telegram Bot 配置（自动验证 Token、用户白名单）

## 安全设计

- Gateway 仅监听 127.0.0.1，不暴露公网管理端口
- Telegram 默认仅白名单用户私聊，群聊关闭
- 配置文件 0600 / 数据目录 0700
- 修改配置前自动备份；CLI 校验通过才生效，失败自动回滚
- 密钥输入不回显，Token 验证失败不落日志

## 环境要求

- Debian 12（其他版本未测试，欢迎反馈）
- root 权限 + SSH 交互终端
- 服务器可访问 api.telegram.org（受限网络请先配置代理）
- 一个模型供应商的 API Key（OpenAI / DeepSeek / OpenRouter / Anthropic 等兼容接口均可）
- 一个 Telegram Bot Token（找 @BotFather 创建）

## 装完之后

- 从白名单内的账号私聊你的 Bot 发送「你好」测试
- 管理工具：`openclaw-manage`（查看配置 / 增删模型 / 切换默认 / 修改 Key / 白名单 / 重启服务）
- 实时日志：`journalctl -u openclaw -f`
- 配置文件：`/root/.openclaw/openclaw.json`

## 常见问题

**Q：支持 Ubuntu / Debian 11 吗？**
未测试，理论大差不差，风险自担；实测结果欢迎提 issue。

**Q：为什么要求 root？**
OpenClaw 默认管理 root 用户下的服务与配置，官方部署形态即如此。

**Q：脚本能重复运行吗？**
可以，按幂等设计；Swap 已存在会拒绝覆盖，配置修改前自动备份。

## 免责声明

本项目按「现状」提供，不附带任何明示或默示担保。使用 OpenClaw 及所配置的模型服务时，请遵守服务器所在地与您所在地的法律法规。

## License

[MIT](LICENSE) © 2026 zhouzijie286-star
