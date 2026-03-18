# FluxBar

FluxBar 是一个基于 `Swift + SwiftUI + AppKit` 的 macOS 菜单栏代理客户端，当前以 `mihomo` 为唯一可用内核目标。

## 当前状态

当前版本：`0.1.1`

已完成的主要能力：

- 菜单栏形态运行，不显示 Dock 图标
- 节点、策略、分流、网络、设置五个主页面
- `mihomo` 内核启动、停止、重启、状态检测
- 配置生成与持久化
- 多订阅读取、直连刷新、节点解析、延迟测试
- 分流规则缓存、规则集解析与展示
- 网络连接实时监控
- 系统代理开关
- 系统代理高级配置（PAC / bypass / guard）
- 开机自启（Login Item）
- 内核自启
- 基于 `mihomo` 内置 TUN 的可用启动链路（支持手动安装/卸载 helper/service）
- 日志面板、内核更新检查、配置管理入口

## 技术栈

- Swift 6
- SwiftUI
- AppKit
- Swift Package Manager
- mihomo controller API

## 构建

在项目根目录执行：

本地构建：

```sh
swift build
```

打包 `.app`：

```sh
sh Scripts/build-local.sh
```

打包 `.dmg`：

```sh
sh Scripts/build-dmg.sh
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
- `TUN` 当前采用 `mihomo` 内置 TUN + 手动安装 helper/service；启用与安装仍需管理员授权
- `系统代理` 模式只能接管遵守系统代理设置的应用；像自带网络栈或直连/QUIC 的应用仍可能漏流量，需要 `TUN`

## 版本说明

`0.1.1` 聚焦逻辑对齐与稳定性修复，重点包括：

- 系统代理、TUN、内核三者状态链路的启动恢复与切换修复
- 策略页隐藏分组能力增强（自动/故转分组、自动选择统一列表）
- 配置目录管理与运行时配置清理策略优化
- 构建产物发布补充 DMG 打包链路
