# Codex Traffic Light

一个 Apple Silicon macOS 菜单栏状态灯，用来提醒 Codex App 当前任务状态。

## 灯态

- 黄灯闪烁: Codex 正在工作
- 黄灯交替: Codex 正在等待你确认权限
- 绿灯常亮: 任务已完成
- 红灯常亮: 任务出错

状态文件位于:

```text
/private/tmp/codex-trafficlight-$(id -u)/status.json
```

## 构建

```bash
/opt/homebrew/bin/rtk scripts/build-app-bundle
```

构建完成后 App 在:

```text
.build/CodexTrafficLight.app
```

可以直接双击，或运行:

```bash
open .build/CodexTrafficLight.app
```

## 安装到应用程序

```bash
/opt/homebrew/bin/rtk scripts/create-app-icon
/opt/homebrew/bin/rtk scripts/build-app-bundle
/opt/homebrew/bin/rtk scripts/install-app
```

安装后可以在 Finder 的“应用程序”里双击 `CodexTrafficLight.app` 打开。

## 安装 Codex Hook

Hook 会和你现有的 `~/.codex/hooks.json` 配置合并，并先生成备份。

```bash
/Users/qingfeng/Documents/trafficlight/scripts/codex-trafficlight install-hooks
```

安装后，Codex 触发 `UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`PermissionRequest`、`Stop` 等事件时，会自动更新状态灯。

## 手动测试

```bash
/Users/qingfeng/Documents/trafficlight/scripts/codex-trafficlight set working "Codex 正在工作"
/Users/qingfeng/Documents/trafficlight/scripts/codex-trafficlight set approval "需要确认权限"
/Users/qingfeng/Documents/trafficlight/scripts/codex-trafficlight set complete "任务已完成"
/Users/qingfeng/Documents/trafficlight/scripts/codex-trafficlight set error "任务出错"
```
