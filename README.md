# FluxBar

FluxBar 是一个基于 `Swift + SwiftUI + AppKit` 的 macOS 菜单栏代理客户端，当前以 `mihomo` 为唯一可用内核目标。

## 当前状态

当前版本：`0.1.0`

已完成的主要能力：

- 菜单栏形态运行，不显示 Dock 图标
- 节点、策略、分流、网络、设置五个主页面
- `mihomo` 内核启动、停止、重启、状态检测
- 配置生成与持久化
- 多订阅读取、直连刷新、节点解析、延迟测试
- 分流规则缓存、规则集解析与展示
- 网络连接实时监控
- 系统代理开关
- 开机自启（Login Item）
- 内核自启
- 基于 `mihomo` 内置 TUN 的可用启动链路
- 日志面板、内核更新检查、配置管理入口

## 技术栈

- Swift 6
- SwiftUI
- AppKit
- Swift Package Manager
- mihomo controller API

## 构建

项目根目录就是当前目录：

```sh
cd /Users/noah/Desktop/FluxBar
```

本地构建：

```sh
swift build
```

打包 `.app`：

```sh
sh Scripts/build-local.sh
```

构建产物默认输出到：

- `BuildArtifacts/Apps/FluxBar.app`
- `BuildArtifacts/ResourcesSnapshot/FluxBar`

## 目录说明

- `App/`：应用入口、全局状态、启动协调器
- `Core/`：内核管理、mihomo controller 客户端
- `Features/`：节点、策略、分流、网络、设置页面
- `Services/`：配置、订阅、网络、更新服务
- `Support/`：持久化、日志、缓存、辅助协调器
- `Resources/`：本地私有编译资源（已加入忽略规则）
- `Scripts/`：打包脚本

## 运行时数据目录

FluxBar 的运行时配置、缓存和日志默认写到：

- `~/Library/Application Support/FluxBar/Configs`
- `~/Library/Application Support/FluxBar/Subscriptions`
- `~/Library/Application Support/FluxBar/State`
- `~/Library/Application Support/FluxBar/Logs`
- `~/Library/Application Support/FluxBar/kernels`

## 已知限制

- 当前仅完整支持 `mihomo`，`smart` 仍是预留位
- `TUN` 当前采用 `mihomo` 内置 TUN + 管理员授权启动链路；尚未实现独立 helper/service
- `系统代理` 模式只能接管遵守系统代理设置的应用；像自带网络栈或直连/QUIC 的应用仍可能漏流量，需要 `TUN`
- 外部面板依赖 `mihomo` 实际成功挂载 `external-ui`

## 版本说明

`0.1.0` 是第一版以“可实际使用”为目标整理出来的发布版本，重点完成了：

- HTML 原型向原生 UI 的高保真迁移
- `mihomo` 运行链路
- 节点/策略/分流/网络/设置页面的真实数据接入
- 配置刷新、规则缓存、延迟持久化、网络监控与设置页基础行为修复
