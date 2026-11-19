# OpenUsage 中文版（个人分支 `zh-cli`）

基于 OpenUsage v0.8.0，在此之上：

- **中文界面**：设置 → 通用 → 语言（跟随系统 / 简体中文 / English），重启后生效。翻译表在 `script/l10n/zh-Hans.py`，构建时生成 `Localizable.strings`。
- **时长格式**：设置 → 通用 → 时长格式：完整（1天2小时）或缩写（1d 2h）。
- **Claude Code CLI 登录**：添加 Claude 账号时选“使用 Claude Code CLI 登录”。读取钥匙串 `Claude Code-credentials`（或 `~/.claude/.credentials.json`）里的 access token，**从不刷新**，不会把 CLI 登出。Token 过期后在终端运行一次 `claude` 即可恢复。
- 不自动更新（无 Sparkle feed），不上报 PostHog 统计。

## 构建

```sh
script/make_signing_identity.sh   # 只需一次：创建本地自签名证书
script/build_zh.sh                # 生成 dist/OpenUsage.app
script/build_zh.sh install        # 构建 + 备份原版到 /Applications/OpenUsage-0.8.0-official.app + 替换并启动
```

跟进上游：`git fetch upstream && git rebase upstream/<tag>`，然后重新构建。
