# macOS RDP 远程桌面客户端：完整开发与进度跟踪文档

> 文档状态：执行中（macOS 11 Intel 启动、端口修复和真实 SOCKS5/HTTP CONNECT 路径已验证；待 RDP 首帧与双平台验收）
> 文档版本：0.2.7
> 最后更新：2026-07-28
> 目标平台：macOS 11 Big Sur 及以上，Intel x86_64 与 Apple Silicon arm64  
> 目标系统：支持 RDP 的 Windows Pro、Enterprise、Windows Server  
> 维护方式：需求、里程碑、风险和决策均在本文档中持续更新

---

## 1. 文档目的

本文档是项目的产品、技术和交付基线，用于：

- 明确“完整版”应用的边界和验收标准。
- 统一产品、设计、macOS、C/C++、测试、安全和发布人员的实现认知。
- 记录需求编号、技术决策、里程碑、依赖、风险和遗留问题。
- 作为迭代计划、周报、发布检查和项目验收的唯一主索引。

本文档不是对工期的承诺。依赖版本、macOS 11 实机兼容性、FreeRDP 功能支持和企业代理行为，必须通过 M0 技术验证后才能锁定。

---

## 2. 项目摘要

### 2.1 产品定位

开发一款运行在 macOS 11 及以上系统的原生远程桌面客户端。用户可以保存多个 Windows 连接配置，通过直接网络、SOCKS5 代理、HTTP CONNECT 代理或 RD Gateway 连接 Windows RDP 服务，并完成稳定、安全、低延迟的桌面控制。

产品优先服务需要连接公司内网、数据中心、云主机和代理网络后目标机器的技术及运维用户。第一发行渠道为经 Developer ID 签名和 Apple 公证的站外 DMG，不把 Mac App Store 作为首发前置条件。

### 2.2 成功标准

正式版必须满足：

1. 在 macOS 11 Intel 和 Apple Silicon 实机上安装、启动、升级和卸载正常。
2. 支持现代 Windows RDP 的 TLS、NLA/CredSSP 登录，不默认允许不安全降级。
3. 直接连接、SOCKS5、HTTP CONNECT 和 RD Gateway 均通过功能与异常测试。
4. 窗口、全屏、Retina、动态分辨率、键鼠、剪贴板、音频和文件重定向可用。
5. 凭据进入 macOS Keychain，日志和崩溃报告不泄露密码、认证材料或剪贴板内容。
6. 应用、框架、动态库和更新包完成签名、公证及完整性验证。
7. 通过本文件第 15 节定义的发布门禁，P0/P1 缺陷清零。

### 2.3 非目标与边界

- 不从零实现 RDP 协议，使用经过审计并固定版本的 FreeRDP。
- 不绕过 Windows 版本、RDS CAL、会话数或组织访问策略限制。
- 不提供规避授权、绕过身份认证、隐藏审计记录或未授权控制能力。
- 不把公网暴露 3389 作为推荐部署方式。企业场景优先采用 RD Gateway、VPN 或受控代理。
- 本项目是 RDP 客户端，不包含类似 AnyDesk 的 Windows Agent、NAT 穿透及全球中继平台。该能力若立项，应建立独立产品和威胁模型。
- 不保证所有 HTTP 代理都允许 CONNECT 到 3389；代理策略拒绝时应给出明确诊断。

---

## 3. 用户与核心场景

### 3.1 目标用户

| 用户 | 主要诉求 | 关键约束 |
|---|---|---|
| 运维/开发人员 | 快速进入多台 Windows 主机 | 多配置、键盘准确、日志可诊断 |
| 企业员工 | 经企业代理或 RD Gateway 进入内网 | 证书、域认证、访问策略 |
| 云服务器管理员 | 管理公网或 VPN 内 Windows 主机 | 稳定性、分辨率、剪贴板和文件 |
| 支持人员 | 在多个会话间切换 | 会话状态清晰、快捷键、审计 |

### 3.2 核心用户流程

1. 新建连接，填写目标主机、账户、显示和资源选项。
2. 选择直接、SOCKS5、HTTP CONNECT 或 RD Gateway 路由。
3. 测试网络路径，保存配置和可选凭据。
4. 发起连接，验证服务器身份，完成 Windows 登录。
5. 在窗口或全屏中控制远程桌面，使用剪贴板、音频和文件映射。
6. 遇到错误时获得分层诊断：本机网络、代理、网关、目标 TCP、TLS、NLA、授权或会话错误。
7. 断开、重连或结束会话；敏感会话状态按设置清理。

---

## 4. 产品需求基线

状态枚举：`待办`、`设计中`、`开发中`、`评审中`、`已完成`、`阻塞`、`取消`。  
优先级枚举：P0 为正式版必需，P1 为高价值完整版能力，P2 为后续增强。

### 4.1 连接与身份认证

| ID | 优先级 | 需求 | 验收摘要 | 状态 |
|---|---:|---|---|---|
| CON-001 | P0 | IPv4、IPv6、主机名及自定义端口连接 | 合法目标可连接，输入校验明确 | 开发中 |
| CON-002 | P0 | TLS 与 NLA/CredSSP | 默认优先安全模式；无静默降级 | 开发中 |
| CON-003 | P0 | 用户名、密码、域账户 | 支持 `DOMAIN\user`、UPN 与本地账户 | 开发中 |
| CON-004 | P0 | 服务器证书验证 | 展示主机、指纹、链和错误；支持受控信任 | 开发中 |
| CON-005 | P0 | 保存、编辑、复制、删除、搜索连接 | 操作不会丢失或串用凭据 | 开发中 |
| CON-006 | P0 | 收藏、最近连接、标签 | 可快速定位常用目标 | 开发中 |
| CON-007 | P0 | 连接、取消、断开、重连 | 状态机无重复连接和资源泄漏 | 开发中 |
| CON-008 | P1 | 从 `.rdp` 导入和导出非敏感配置 | 密码与密钥绝不导出 | 开发中 |
| CON-009 | P1 | 多会话窗口及标签页 | 单个会话崩溃不拖垮其他会话 | 开发中 |
| CON-010 | P1 | 会话超时、自动重连策略 | 可配置次数和退避；不无限重试认证 | 开发中 |
| CON-011 | P1 | Kerberos/智能卡等企业认证评估 | 以 M0/M1 能力矩阵确定正式范围 | 设计中 |

### 4.2 网络路径与代理

| ID | 优先级 | 需求 | 验收摘要 | 状态 |
|---|---:|---|---|---|
| NET-001 | P0 | 直接 TCP 连接 | DNS、IPv4、IPv6、超时和取消可控 | 开发中 |
| NET-002 | P0 | SOCKS5 无认证和用户名/密码认证 | 支持代理端 DNS，错误可定位到握手阶段 | 开发中 |
| NET-003 | P0 | HTTP CONNECT | 支持无认证和 Basic；安全处理 407/403 等响应 | 开发中 |
| NET-004 | P0 | 每个连接独立路由配置 | 不污染系统代理或其他连接 | 开发中 |
| NET-005 | P0 | 连接路径测试 | 分别显示 DNS、代理、目标端口和握手结果 | 开发中 |
| NET-006 | P0 | 本地回环隧道 | 仅绑定 loopback，随机端口，生命周期与会话一致 | 开发中 |
| NET-007 | P0 | 原始目标身份透传 | 经隧道时仍按原目标名做证书与网关策略校验 | 开发中 |
| NET-008 | P1 | RD Gateway over HTTPS/443 | 支持网关与目标独立凭据、证书和错误 | 开发中 |
| NET-009 | P1 | 代理 TLS（HTTPS proxy） | 验证代理证书，不允许全局关闭校验 | 开发中 |
| NET-010 | P1 | PAC/系统代理评估 | 明确是否适合非 HTTP 的 RDP 路径 | 设计中 |
| NET-011 | P1 | TCP keepalive、网络切换与退避 | Wi-Fi 切换后行为可预测 | 开发中 |
| NET-012 | P2 | SSH 隧道 | 独立安全评审后纳入 | 待办 |

说明：M0 需要确认 FreeRDP 当前选定版本能否接受已有 socket/自定义 BIO。若接口稳定，传输层直接注入连接；若不稳定，使用受控的 `127.0.0.1:[随机端口]` 本地转发。后一种方案必须把原始目标主机名独立传给证书校验和 RDP 设置层。

### 4.3 显示、输入与会话体验

| ID | 优先级 | 需求 | 验收摘要 | 状态 |
|---|---:|---|---|---|
| UX-001 | P0 | AppKit 原生连接管理界面 | macOS 11 视觉及交互正常 | 开发中 |
| UX-002 | P0 | Core Graphics 首屏渲染 | 建链后正确显示、缩放和刷新 | 开发中 |
| UX-003 | P0 | Metal 高性能渲染 | 无明显撕裂；CPU/内存符合性能预算 | 开发中 |
| UX-004 | P0 | Retina 和缩放 | backing scale、逻辑点与远程像素映射正确 | 开发中 |
| UX-005 | P0 | 动态分辨率 | 窗口调整防抖，无连续重置风暴 | 开发中 |
| UX-006 | P0 | 窗口和全屏 | 菜单栏、Dock、多空间行为符合 macOS | 开发中 |
| UX-007 | P0 | 鼠标移动、按键、滚轮 | 坐标、左右键、精确滚动正确 | 开发中 |
| UX-008 | P0 | 键盘扫描码与组合键 | 按下/释放成对；焦点丢失时释放全部按键 | 开发中 |
| UX-009 | P0 | Mac/Windows 快捷键模式 | Command、Option、Control 映射可选 | 开发中 |
| UX-010 | P0 | 发送 Ctrl+Alt+Delete | 使用协议支持的安全序列 | 开发中 |
| UX-011 | P0 | 剪贴板文本与图片 | 双向、可禁用、大小受限、失败可恢复 | 待办 |
| UX-012 | P1 | 文件剪贴板/拖放 | 明确用户授权、进度、取消和路径边界 | 待办 |
| UX-013 | P1 | 多显示器 | 排列、缩放不同的屏幕下正确 | 待办 |
| UX-014 | P1 | 输入法与国际键盘 | 中文、英文及至少三种布局通过测试 | 开发中 |
| UX-015 | P1 | 会话工具栏 | 图标按钮、工具提示、状态与权限清晰 | 开发中 |
| UX-016 | P1 | 可访问性 | VoiceOver、键盘导航、对比度通过检查 | 开发中 |

### 4.4 资源重定向

| ID | 优先级 | 需求 | 验收摘要 | 状态 |
|---|---:|---|---|---|
| RED-001 | P1 | 远端音频播放 | 可选质量、设备变化可恢复 | 开发中 |
| RED-002 | P1 | 麦克风重定向 | 默认关闭，首次启用说明并请求系统权限 | 开发中 |
| RED-003 | P1 | 文件夹/磁盘映射 | 默认关闭；限定用户选择目录和读写权限 | 开发中 |
| RED-004 | P1 | 打印机重定向 | 能力评估后确定支持矩阵 | 设计中 |
| RED-005 | P1 | 摄像头重定向 | 能力和性能评估后确定支持矩阵 | 设计中 |
| RED-006 | P1 | 时区、智能卡等设备通道 | 每类通道独立开关和安全评审 | 设计中 |
| RED-007 | P0 | 重定向策略预设 | 安全、标准、完整三档，默认安全 | 开发中 |

“完整版”不等于无条件承诺所有 FreeRDP 通道。RED-004 至 RED-006 必须根据选定 FreeRDP 版本、Windows 目标矩阵和 macOS 11 权限机制完成可行性验证；若无法达到发布质量，应在正式版能力矩阵中明确标注而不是以实验状态默认开启。

### 4.5 数据、设置、诊断与更新

| ID | 优先级 | 需求 | 验收摘要 | 状态 |
|---|---:|---|---|---|
| APP-001 | P0 | 本地配置数据库 | 有 schema 版本、迁移、备份和损坏恢复 | 开发中 |
| APP-002 | P0 | Keychain 凭据存储 | Windows、代理和网关凭据隔离引用 | 开发中 |
| APP-003 | P0 | 全局与连接级设置 | 覆盖优先级明确，恢复默认值可控 | 开发中 |
| APP-004 | P0 | 结构化日志 | 分层级和类别；默认脱敏；用户可导出 | 开发中 |
| APP-005 | P0 | 隐私安全诊断包 | 用户预览内容后导出，不含密钥和剪贴板 | 开发中 |
| APP-006 | P0 | 崩溃恢复 | 不自动重连敏感会话；配置数据不损坏 | 开发中 |
| APP-007 | P0 | 自动更新 | 签名 feed、包完整性验证、回滚策略 | 设计中 |
| APP-008 | P0 | 首次启动与版本迁移 | 无强制注册，迁移失败可诊断 | 开发中 |
| APP-009 | P1 | 配置备份/恢复 | 默认不包含密码；格式版本化 | 开发中 |
| APP-010 | P1 | 管理策略 | 支持企业预配置和限制高风险重定向 | 开发中 |
| APP-011 | P1 | 本地化 | 简体中文、英文首发，文案可扩展 | 开发中 |

---

## 5. 非功能需求

### 5.1 性能预算

所有指标均需在 M0 建立基准机型和可复现测试条件后锁定。初始目标如下：

| 指标 | 初始目标 | 测试条件 |
|---|---:|---|
| 冷启动到主界面 | P95 小于 2 秒 | 受支持最低规格 Mac，缓存正常 |
| 连接取消响应 | 小于 500 ms | DNS、代理和 TCP 任一阶段 |
| 局域网交互延迟增量 | 小于 25 ms | 以网络 RTT 之外的客户端处理计算 |
| 1080p 常规办公刷新 | 30 FPS 可持续 | 文档、浏览器、窗口滚动 |
| 活跃会话内存 | 目标小于 350 MB | 单个 1080p 会话，不含文件缓存 |
| 空闲会话 CPU | 平均小于 5% 单核 | 画面无更新、音频关闭 |
| 连接配置容量 | 至少 1,000 条 | 搜索和启动无明显卡顿 |

4K、双屏、视频播放和高延迟代理场景单独制定档位，不能只用局域网 1080p 结果代表发布质量。

### 5.2 稳定性与可靠性

- 连续 8 小时办公会话无崩溃、无持续内存增长。
- 反复连接/断开 500 次无句柄、线程和端口泄漏。
- 网络断开、睡眠唤醒、屏幕切换、代理拒绝和目标重启均有确定状态转换。
- 配置写入采用事务或原子替换；任何崩溃点不应破坏已有配置。
- FreeRDP 会话运行在隔离执行域；评估 XPC 进程隔离，正式版前由 ADR 决定。

### 5.3 兼容性矩阵

| 类别 | 最低覆盖 |
|---|---|
| macOS 客户端 | 11.x、当前稳定版；Intel 与 Apple Silicon |
| Windows 目标 | Windows 10/11 Pro/Enterprise、Windows Server 2016/2019/2022/2025 |
| Windows 安全 | TLS、NLA；禁用旧 RDP Security 为默认建议 |
| 显示 | 非 Retina、Retina、1080p、1440p、4K、不同 DPI 多屏 |
| 键盘 | ANSI、ISO；中英文输入和常见欧洲布局 |
| 代理 | SOCKS5、Squid/兼容 HTTP CONNECT、至少一种企业代理 |
| 网关 | 至少两个受支持 Windows Server RD Gateway 版本 |

Windows Home 通常不能作为受支持的微软 RDP 主机，应在 UI 和文档中明确。

---

## 6. 总体架构

```text
┌──────────────────────────────── macOS App ────────────────────────────────┐
│ AppKit UI                                                                  │
│ 连接列表 │ 编辑器 │ 会话窗口 │ 设置 │ 诊断 │ 更新                         │
├───────────────────────────────────────────────────────────────────────────┤
│ Swift Application Layer                                                   │
│ SessionCoordinator │ ProfileStore │ CredentialStore │ Policy │ Telemetry   │
├───────────────────────────────────────────────────────────────────────────┤
│ Objective-C++ Bridge (稳定、窄接口、无 FreeRDP 类型泄漏到 Swift)           │
├───────────────────────┬───────────────────────┬───────────────────────────┤
│ FreeRDP Session Core  │ Transport Abstraction │ Redirection Controllers   │
│ auth / channels       │ direct / SOCKS / HTTP │ clipboard / audio / drive │
├───────────────────────┴───────────────────────┴───────────────────────────┤
│ Renderer: Metal + Core Graphics fallback │ Keychain │ SQLite │ os_log       │
└───────────────────────────────────────────────────────────────────────────┘
                          │
             Direct / Proxy / RD Gateway
                          │
                 Windows RDP Service
```

### 6.1 分层职责

| 层/模块 | 责任 | 禁止事项 |
|---|---|---|
| AppKit UI | 展示状态、接收用户意图、窗口和输入事件 | 不直接调用 FreeRDP C API |
| Application Layer | 会话编排、配置、策略、错误映射 | 不持有明文密码超过必要生命周期 |
| RDP Bridge | 封装上下文、回调、线程和数据结构 | 不把 FreeRDP 指针暴露给 Swift |
| Transport | DNS、TCP、SOCKS5、CONNECT、取消、超时 | 不决定服务器证书信任 |
| Renderer | 帧更新、颜色格式、缩放、显示同步 | 不处理认证和网络策略 |
| Redirection | 每种虚拟通道的权限和生命周期 | 不默认开放本地资源 |
| Persistence | 配置模型、迁移、Keychain 引用 | 不在 SQLite/UserDefaults 存密码 |
| Diagnostics | 结构化事件、脱敏和导出 | 不记录认证令牌和用户内容 |

### 6.2 会话状态机

```text
Idle
  -> Resolving
  -> ConnectingTransport
  -> NegotiatingProxyOrGateway
  -> NegotiatingTLS
  -> Authenticating
  -> ConfiguringChannels
  -> Connected
  -> Reconnecting (可选、有限次数)
  -> Disconnecting
  -> Closed

任一中间状态 -> Failed(errorCategory, recoverability)
任一可取消状态 -> Cancelling -> Closed
```

所有网络、认证和 FreeRDP 回调必须转换为串行状态事件。UI 只消费不可变会话快照，避免多线程直接更新视图。

### 6.3 线程与进程模型

- 主线程：AppKit 事件与轻量状态渲染。
- 每会话串行执行器：FreeRDP 事件循环、连接和状态转换。
- 网络执行器：可取消的代理握手、数据转发和超时。
- 渲染队列：纹理上传、脏矩形合并与显示同步。
- 音频队列：与 UI/网络隔离，避免音频回调阻塞。
- 后台服务：数据库迁移、诊断包和更新下载。

在 M1 完成前做 XPC 隔离原型：比较崩溃隔离、安全边界、帧传输成本和复杂度。若不采用 XPC，也必须保证每会话资源可独立销毁，并通过 AddressSanitizer/ThreadSanitizer 验证。

---

## 7. 关键技术设计

### 7.1 技术栈

| 领域 | 选型 | 说明 |
|---|---|---|
| UI | Swift + AppKit | macOS 11 输入、窗口和生命周期控制更成熟 |
| 桥接 | Objective-C++ | 隔离 Swift ABI 与 C/C++ 依赖 |
| RDP | FreeRDP 固定版本 | M0 验证后记录精确 commit/tag 和补丁 |
| 渲染 | Metal，Core Graphics fallback | 先建立正确性，再优化性能 |
| 网络 | Network.framework/BSD socket + 自研小型握手层 | 不引入功能过重的代理依赖 |
| 音频 | Core Audio/AVFoundation | 按通道需求选择最小接口 |
| 数据 | SQLite + 显式迁移 | 连接模型需要版本化和可靠恢复 |
| 凭据 | Security.framework / Keychain | 每类凭据独立 service/account 标识 |
| 日志 | os_log + 内部结构化事件 | 支持隐私标记与导出脱敏 |
| 构建 | Xcode + CMake | 原生 App 与第三方 C/C++ 双构建链 |
| 测试 | XCTest/XCUITest + CTest + 网络故障测试台 | 分层测试 |
| 更新 | Sparkle 2 或等价签名更新框架 | M0 核验 macOS 11 与架构支持后决定 |

不得在验证前把任何第三方库的“最新版本”直接写入锁文件。所有依赖必须包含版本、来源、校验和、许可证、最低系统要求和安全更新责任人。

### 7.2 代理与本地隧道

统一接口示意：

```swift
enum RouteConfiguration {
    case direct
    case socks5(ProxyEndpoint, credentialRef: CredentialReference?)
    case httpConnect(ProxyEndpoint, tls: Bool, credentialRef: CredentialReference?)
    case rdGateway(GatewayConfiguration)
}

struct TargetIdentity {
    let host: String
    let port: UInt16
    let certificateName: String
}
```

约束：

- SOCKS5 使用域名地址类型时由代理解析 DNS，避免本地 DNS 泄漏。
- HTTP 响应头设置硬上限，拒绝无限响应、畸形状态行和认证循环。
- 第一阶段只实现 HTTP Basic；Digest、Negotiate/NTLM 必须单独评估，不以 Basic 代替企业认证。
- 本地转发仅监听 `127.0.0.1` 和/或 `::1`，采用系统分配端口，不向局域网暴露。
- 连接取消必须关闭监听器、上游 socket、下游 socket 和计时器。
- 隧道日志只记录阶段、耗时和错误代码，不记录 `Proxy-Authorization`。
- 每个连接显式保存 `TargetIdentity`，证书验证不得因 FreeRDP 实际连接 `localhost` 而失去目标身份。

### 7.3 渲染管线

1. FreeRDP 输出统一 BGRA/RGBA 帧格式或可转换表面。
2. 收集脏矩形，在渲染队列合并，限制单帧上传次数。
3. Metal 使用可复用纹理和 staging buffer；Core Graphics 用于故障回退和测试基准。
4. 渲染按远程帧节奏触发，不无条件 60 FPS 空转。
5. 视图坐标、backing pixel、远端坐标采用单一转换函数，输入和显示共用。
6. 动态分辨率变更进行 200 至 350 ms 防抖，最终数值按 RDP 能力对齐。

### 7.4 输入模型

- 基于 `NSEvent` 读取物理按键和修饰键，转换为 Windows 扫描码。
- 维护本地按键集合；窗口失焦、断连和模式切换时发送必要的 key-up。
- 默认保留 macOS 必需的系统快捷键，提供“Mac 优先”和“Windows 优先”模式。
- 安全序列、Windows 键、Print Screen 等通过会话工具栏和映射表提供。
- 输入法需要分别测试组合文本、候选状态和直接扫描码路径，不能只靠字符注入。
- 鼠标捕获只在会话视图激活时生效，不申请非必要的全局辅助功能权限。

### 7.5 数据模型

```text
ConnectionProfile
  id, name, targetHost, targetPort, usernameHint, domainHint
  routeConfiguration, displayConfiguration, redirectionPolicy
  certificatePolicy, reconnectPolicy, tags, timestamps, schemaVersion

CredentialReference
  id, profileId, kind(target|proxy|gateway), keychainPersistentRef

KnownHost
  normalizedHost, port, certificateFingerprint, firstSeen, lastSeen, decision

AppSettings
  locale, updateChannel, keyboardMode, loggingLevel, privacyPreferences
```

密码不进入 `ConnectionProfile`。用户名可保存；密码、代理密码和网关秘密只通过短生命周期缓冲区交给协议层，用后清零最佳努力执行。

### 7.6 错误分类

用户错误必须保留可执行的下一步，同时包含可供支持人员定位的错误码：

| 类别 | 示例 | 用户提示方向 |
|---|---|---|
| LOCAL | 离线、权限、本地端口失败 | 检查 Mac 网络或权限 |
| DNS | 目标/代理解析失败 | 检查名称或改用代理 DNS |
| PROXY | 407、拒绝、协议异常 | 核对代理类型、凭据和策略 |
| GATEWAY | 网关认证、授权、证书 | 核对网关和企业策略 |
| TARGET | 连接拒绝、超时 | 检查目标地址、3389、防火墙 |
| TLS | 证书过期、名称不符、链不可信 | 展示证书详情，不自动忽略 |
| AUTH | NLA 凭据失败、账户限制 | 核对域、账户和权限 |
| RDP | 协商、许可、通道失败 | 展示阶段和兼容建议 |
| SESSION | 断线、服务端结束、资源不足 | 重连或联系管理员 |

---

## 8. 安全与隐私设计

### 8.1 威胁模型资产

重点保护：Windows/代理/网关凭据、服务器身份决定、远端画面、剪贴板、映射文件、诊断日志、更新通道和本地连接配置。

主要威胁：

- 恶意或被劫持的代理实施中间人攻击。
- 用户误信伪造或变化的 RDP 证书。
- FreeRDP/编解码/虚拟通道处理恶意服务器数据时发生内存安全问题。
- 本地其他进程读取 loopback 隧道、配置、日志或临时文件。
- 剪贴板和磁盘映射造成跨安全边界数据泄漏。
- 更新 feed、安装包或依赖供应链被篡改。

### 8.2 强制控制

- Keychain 项默认 `WhenUnlocked`，是否启用设备同步需明确产品决策，默认关闭。
- 首次未知证书要求用户确认；证书变化强警告，不能以普通提示自动覆盖。
- 明文 HTTP 代理只保护代理握手，不保护代理到目标的 TCP；RDP 自身 TLS 仍必须验证目标。
- 重定向默认采用“安全”预设：关闭磁盘、麦克风、摄像头、打印机和智能卡。
- 临时文件使用用户私有目录、最小权限，并在异常退出后清理。
- Hardened Runtime、Library Validation 和最小 entitlement；任何例外写入 ADR。
- 构建产物生成 SBOM；依赖进行许可证和 CVE 扫描。
- 发布密钥不存储于源码或普通 CI 变量；使用受控签名环境。
- 更新元数据与包均验证签名；禁止仅依赖 HTTPS。
- 安全问题建立私密报告渠道和修复 SLA。

### 8.3 日志脱敏规则

禁止记录：密码、Keychain 引用原值、Authorization 头、NTLM/Kerberos/CredSSP 材料、完整剪贴板、文件内容、屏幕帧。

默认哈希或部分遮盖：用户名、主机名、IP、文件路径、证书主题。用户主动生成支持包时，应能预览并选择是否包含网络地址。

### 8.4 安全验证

- 代理解析器和 Objective-C++ 边界做 libFuzzer/AFL++ 或等效模糊测试。
- AddressSanitizer、UndefinedBehaviorSanitizer、ThreadSanitizer 分别跑测试套件。
- 对证书首次信任、名称不匹配、过期、链变化和代理 MITM 建立自动/半自动用例。
- 正式版前完成一次独立渗透测试和依赖供应链审查。

---

## 9. 仓库与代码组织

建议的单仓库结构：

```text
RemoteDesktop/
├── App/                         # Swift/AppKit 主应用
│   ├── Application/
│   ├── Features/Connections/
│   ├── Features/Session/
│   ├── Features/Settings/
│   └── Resources/
├── RDPBridge/                   # Objective-C++ 稳定封装
├── RDPTransport/                # direct/SOCKS5/HTTP 隧道
├── RDPRenderer/                 # Metal/Core Graphics
├── RDPRedirection/              # 剪贴板、音频、文件等控制器
├── Persistence/                 # SQLite、迁移和 Keychain
├── Diagnostics/
├── Vendor/                      # 固定第三方源码/构建描述，不提交产物
├── Tests/
│   ├── Unit/
│   ├── Integration/
│   ├── UI/
│   ├── Compatibility/
│   └── Fixtures/
├── Tools/                       # 构建、签名、SBOM、发布脚本
├── Docs/
│   ├── adr/
│   ├── security/
│   ├── protocols/
│   ├── testing/
│   └── release/
├── Config/
├── RemoteDesktop.xcodeproj
├── CMakeLists.txt
└── DEVELOPMENT_PLAN.md
```

### 9.1 编码与评审规则

- Swift 开启严格警告并逐步采用严格并发检查可支持的子集。
- C/C++ 警告视为错误，公共边界使用显式所有权和空值约定。
- Objective-C++ 桥接 API 要有线程、生命周期、错误和回调队列说明。
- 新功能必须引用需求 ID；修复必须附回归测试或说明无法自动化的原因。
- 任何认证、证书、代理、更新、重定向变更需要安全评审。
- 不允许未经 ADR 的全局“忽略证书错误”、明文秘密、永久调试日志或私有 API。

### 9.2 分支与版本

- 主干：`main`，始终保持可构建。
- 短分支：`feature/REQ-ID-description`、`fix/ISSUE-ID-description`。
- 版本：Semantic Versioning；应用 build number 单调递增。
- 发布通道：`internal`、`beta`、`stable`，通道间使用独立 feed。
- 第三方依赖升级单独 PR，附兼容、安全和许可证结果。

---

## 10. 开发环境与构建策略

### 10.1 必需环境

- 一台仍可运行 macOS 11 的 Intel Mac。
- 一台 Apple Silicon Mac，至少有一套 macOS 11 验证环境或真实设备。
- 能构建目标 deployment target 11.0 的受控 Xcode 工具链。
- Windows 10、Windows 11、Windows Server 测试机与 RD Gateway。
- SOCKS5 与 HTTP CONNECT 测试代理，支持成功、拒绝、认证和延迟注入。
- Apple Developer Program、Developer ID Application 证书和公证凭据。

注意：支持旧系统并不意味着可长期使用旧 Xcode。M0 必须验证“构建工具链支持当前签名/公证要求”与“产物 deployment target 为 11.0”可以同时满足，并记录可复现工具链。

### 10.2 Universal 2 依赖

所有原生依赖分别以 `arm64` 和 `x86_64` 构建，确保：

- 两个 slice 使用一致的 feature flags、ABI 和 deployment target。
- 不使用来自本机包管理器的未锁定绝对路径。
- 合并后验证架构、install name、rpath、签名和最小系统版本。
- 应用启动时不从包外加载未签名动态库。

### 10.3 CI 流水线

每个 PR：

1. 格式和静态分析。
2. Swift/C/C++ 单元测试。
3. 两架构编译和链接检查。
4. 代理协议集成测试。
5. 许可证、秘密和依赖漏洞扫描。
6. 产出未公证内部构建供测试。

主干每日：

1. Windows 兼容环境连接冒烟。
2. 连接/断开循环与内存检查。
3. UI 自动化与截图比较。
4. ASan/UBSan；TSan 可按独立任务运行。
5. Universal 2 包结构和代码签名预检。

候选版本：完整回归、SBOM、归档、签名、公证、staple、离线 Gatekeeper 验证和升级路径测试。

---

## 11. 测试策略

### 11.1 测试层次

| 层次 | 内容 | 自动化目标 |
|---|---|---:|
| 单元测试 | 状态机、配置迁移、映射、解析器、脱敏 | 高 |
| 组件测试 | Transport、Bridge、Renderer、Keychain 封装 | 高 |
| 协议集成 | SOCKS5/CONNECT/RDP 测试端点 | 高 |
| 系统测试 | 真实 Windows、网关、音视频与重定向 | 中 |
| UI 测试 | 新建连接、证书弹窗、会话工具栏、设置 | 中 |
| 兼容测试 | OS/CPU/Windows/代理/显示矩阵 | 半自动 |
| 安全测试 | fuzz、证书、秘密扫描、篡改与权限 | 高+人工 |
| 长稳测试 | 8/24 小时、断网、睡眠、循环连接 | 自动化 |

### 11.2 必测故障场景

- DNS NXDOMAIN、慢 DNS、IPv6 不通后 IPv4 策略。
- SOCKS5 方法不支持、认证失败、目标拒绝和回复截断。
- HTTP 407/403/502、超大头、慢响应、代理认证循环。
- 目标 3389 拒绝、黑洞超时、握手中断、服务端重置。
- RDP 证书未知、过期、名称不匹配、指纹变化。
- NLA 密码错误、域错误、账户锁定、密码过期。
- 窗口缩放时断连、全屏切换、外接显示器拔出。
- 按键按下时失焦、Command/Option 切换、中文输入法组合态。
- 大剪贴板、异常图片、循环同步、禁用时的数据隔离。
- 文件映射符号链接、权限变化、超大文件、磁盘空间不足。
- 睡眠唤醒、Wi-Fi 切换、代理切换、目标重启。
- 更新包截断、签名错误、版本回退和 feed 被篡改。

### 11.3 测试数据原则

- 使用专用测试账户和无真实敏感信息的 Windows 镜像。
- 证书、代理和网络错误通过隔离测试实验室生成。
- 截图测试使用固定测试桌面，不采集员工真实远程画面。
- 诊断包进入 CI 断言：不可出现已知测试密码或认证头。

---

## 12. 交互与界面清单

### 12.1 主要窗口

- 连接库：侧边栏标签/收藏，主列表，搜索，新增和连接动作。
- 连接编辑器：常规、显示、网络、资源、安全、高级六个分区。
- 会话窗口：远程画布、可自动隐藏工具栏、状态覆盖层。
- 首次证书/证书变化对话框：信息层次清楚，危险操作不作为默认按钮。
- 设置：通用、键盘、显示、隐私、更新、诊断。
- 诊断：阶段时间线、可复制错误码、脱敏支持包预览。

### 12.2 会话工具栏命令

使用系统或 Lucide/SF Symbols 中语义稳定的图标并提供工具提示：断开、重连、全屏、缩放、动态分辨率、发送安全序列、键盘模式、剪贴板开关、音频、文件夹映射和会话信息。

### 12.3 状态与反馈

- 连接覆盖层显示当前阶段，不展示虚假百分比。
- 取消始终可用，超过阈值时记录不可取消调用位置。
- 错误页包含简短原因、建议操作、技术错误码和诊断入口。
- 网络重连时远程画面明确冻结并显示状态，避免用户误以为输入仍在生效。

---

## 13. 里程碑与工作分解

以下周期按 4 人核心团队估算：1 名 macOS/产品端、1 名 C/C++/RDP、1 名网络/安全、1 名 QA/自动化；设计、Windows/RDS、发布能力按需支持。资源减少时应调整交付日期或范围，不应压缩安全与测试门禁。

| 里程碑 | 建议周期 | 目标 | 退出条件 | 状态 |
|---|---:|---|---|---|
| M0 技术验证与基线 | 3 周 | 消除最高技术风险 | 双架构启动、直连/NLA、SOCKS/CONNECT PoC、渲染与输入 PoC | 阻塞 |
| M1 核心骨架 | 4 周 | 建立可持续架构 | 状态机、Bridge、数据模型、Keychain、CI 可用 | 开发中 |
| M2 核心远程桌面 | 6 周 | 日常基础会话可用 | 直连、代理、证书、窗口/全屏、Retina、键鼠通过 | 开发中 |
| M3 生产体验 | 5 周 | 完成主要工作流 | 多配置、多会话、剪贴板、动态分辨率、诊断、重连 | 开发中 |
| M4 完整网络与资源 | 7 周 | 补齐完整版能力 | RD Gateway、音频、磁盘、多屏及已批准通道 | 开发中 |
| M5 安全与兼容硬化 | 5 周 | 达到候选发布质量 | 兼容矩阵、长稳、fuzz、性能、安全评审完成 | 待办 |
| M6 Beta 与发布 | 4 周 | 签名公证正式交付 | Beta 反馈关闭、更新链路、文档、发布门禁通过 | 待办 |

基线总周期约 34 周，不含外部渗透测试排期、证书申请、企业代理协调和 M0 发现的 FreeRDP/macOS 11 兼容修复。

### 13.1 M0：技术验证与基线

- [~] `M0-01` 已锁定 FreeRDP 3.30.0/commit，许可证已记录，CI 双架构编译和 macOS 11 运行时加载已通过；CVE 审查和 Windows 连接验证未完成。
- [~] `M0-02` GitHub Actions 已构建 x86_64 slice；修复后的产物已在 macOS 11.7.10 Intel 实机启动并创建 `900x608` 主窗口。验证机当前锁屏，窗口服务器的解锁态 onscreen 复验尚未完成。
- [~] `M0-03` arm64 Swift 测试、FreeRDP 编译及 Universal 2 slice 已通过；待 macOS 11 Apple Silicon 实机启动。
- [x] `M0-04` 已合成 Universal 2，并在 CI 和 macOS 11 Intel 实机验证应用内全部 12 个 Mach-O 文件同时包含 arm64/x86_64 slice。
- [~] `M0-05` macOS 11 Intel 已通过真实 Windows 目标的 TLS/NLA 并收到首帧；Windows 10/11/Server 完整矩阵仍待补齐。
- [~] `M0-06` SOCKS5 和 HTTP CONNECT 的代理握手及目标隧道已在 macOS 11 验证；完整 RDP 会话的逻辑服务器名修复待 CI 与首帧验收。
- [~] `M0-07` 已实现 `CertificateName` 原始目标传递，待真实证书验证。
- [~] `M0-08` macOS 11 Intel 已收到并显示真实远程首帧；Core Graphics fallback、帧缩放和键鼠输入矩阵仍待验收。
- [~] `M0-09` Metal 纹理上传和输入坐标原型已编写，待性能验证。
- [ ] `M0-10` 验证 RD Gateway、音频、磁盘、多屏及各重定向能力。
- [~] `M0-11` Xcode 15.4、11.0 deployment target、Swift Concurrency 回部署和 ad-hoc 签名组合已通过；Developer ID 签名与公证未验证。
- [~] `M0-12` 能力矩阵与 ADR 已建立；性能基线和实测工期待 Mac 实验室。

### 13.2 M1：核心骨架

- [~] `M1-01` 仓库、XcodeGen/CMake 配置已建立，Xcode 15.4 工程生成和 Release/Debug 编译已通过；静态分析仍待验证。
- [~] `M1-02` FreeRDP 3.30.0 双架构编译、合并和运行时打包已通过；OpenSSL 精确来源锁定和全部通道能力验证仍需完成。
- [~] `M1-03` Bridge API、所有权、主线程回调和原生取消源码已实现并编译通过，待专项代码评审和竞态测试。
- [x] `M1-04` 会话状态机及其单元测试已在 arm64/x86_64 两套 Swift 测试任务中通过。
- [~] `M1-05` 连接模型、SQLite schema v1、WAL、迁移框架、配置大小门禁、回滚失败报告、三文件隔离恢复事务及删除事务已编写并通过自动化测试；损坏恢复人工验收未完成。
- [~] `M1-06` Keychain 隔离引用、临时凭据、两阶段写入、删除后清理及回滚残留错误报告已编写，待 macOS Keychain 故障注入测试。
- [~] `M1-07` 结构化诊断、错误分类、敏感字段脱敏及私有字段导出限制测试已编写并通过自动化测试，待隐私评审。
- [x] `M1-08` GitHub Actions 双架构 CI 已建立；运行 `30316764662` 全部通过：arm64/x86_64 Swift 测试、FreeRDP 双架构编译、AppKit 生命周期与 renderer 测试、Universal 2 构建、签名和依赖闭包门禁均成功。
- [~] `M1-09` 已记录线程隔离临时 ADR；XPC 原型和最终决策未完成。

### 13.3 M2：核心远程桌面

- [~] `M2-01` 连接库和六分区编辑器源码已实现，待 UI 验收。
- [~] `M2-02` Direct 路径已在 macOS 11 Intel 完成真实 Windows TLS/NLA 和首帧验证；长稳及 Windows 版本矩阵待补齐。
- [~] `M2-03` SOCKS5 无认证/用户名密码、代理 DNS、IPv4/IPv6 字面量 ATYP 编码、编码前凭据边界、Keychain 缺失时临时代理凭据提示及取消语义源码和协议测试已编写。
- [~] `M2-04` HTTP/HTTPS CONNECT Basic、防注入、16 KiB 请求上限、响应上限及失败连接回收源码和协议测试已编写。
- [~] `M2-05` 15 秒路径测试、路由阶段错误和目标/代理/网关统一入口校验已实现，DNS/代理细分展示待完善并验收。
- [~] `M2-06` 首次信任与证书变化告警源码已实现，待证书链信息和实测。
- [~] `M2-07` 会话窗口、Core Graphics fallback 与 Metal 渲染已编译；帧长度/步幅/溢出校验和 256 MiB 上限已统一，桥接层仅保留最新一帧；macOS 11 Intel 已显示真实首帧，关闭竞态和性能验收待完成。
- [~] `M2-08` Retina 坐标、窗口缩放和全屏源码已实现，待多 DPI/多空间验收。
- [~] `M2-09` 鼠标、滚轮、扫描码、修饰键释放源码已实现，待布局矩阵。
- [~] `M2-10` 键盘模式、安全序列和 Command 捕获差异已实现，待组合键及布局矩阵验收。

### 13.4 M3：生产体验

- [~] `M3-01` 收藏、最近记录、标签、名称/主机/标签搜索和复制源码已实现；标签与字面通配符数据库测试已编写，待 macOS 运行和 UI 验收。
- [~] `M3-02` 独立会话窗口、session ID、回调与隧道隔离已实现；标签页/XPC 隔离待完成。
- [~] `M3-03` 动态分辨率和多 DPI 基础支持已实现；等待 Windows 真机确认远端 framebuffer 尺寸变化及多显示器 DPI 验收。
- [ ] `M3-04` 文本与图片剪贴板、策略和大小限制。
- [~] `M3-05` 有限指数退避、认证失败禁止重试、睡眠和网络切换监听已实现，待故障注入验收。
- [~] `M3-06` 诊断时间线、脱敏、预览、清理和导出 UI 已实现；MDM 可禁止私有数据导出，待隐私审查。
- [~] `M3-07` 设置、首次启动、严格 schema 校验、迁移/损坏隔离及 8 MiB 配置/64 MiB 归档门禁源码已实现，待升级与恢复测试。
- [~] `M3-08` 英文 key 与简体中文资源、工具提示和基础可访问性标签已实现，待 VoiceOver/键盘导航验收。
- [~] `M3-09` `.rdp` 非敏感导入/导出、1 MiB 流式输入门禁及 Finder 打开队列已实现，待兼容文件矩阵验收。

### 13.5 M4：完整网络与资源

- [~] `M4-01` RD Gateway 配置和独立 Keychain 凭据已接入 FreeRDP 设置，待真实网关验证。
- [ ] `M4-02` RD Gateway 错误分类与企业测试环境回归。
- [ ] `M4-03` 远端音频播放和设备切换。
- [ ] `M4-04` 麦克风重定向及权限流程。
- [~] `M4-05` 用户选择、安全作用域书签、书签数量/名称/单项大小边界与会话授权生命周期已实现；rdpdr 设备注册待锁定头文件和 Mac 验证。
- [ ] `M4-06` 文件剪贴板/拖放及安全边界。
- [ ] `M4-07` 多显示器和不同缩放组合。
- [ ] `M4-08` 打印机、摄像头、智能卡等能力按 M0 决策实施。
- [~] `M4-09` 企业 MDM 策略解析、强制设置覆盖、重连/缩放/重定向限制、凭据保存与诊断导出控制及设置 UI 锁定已接入源码，待 Mac 编译、真实 MDM 下发和管理员验收。

### 13.6 M5：安全与兼容硬化

- [ ] `M5-01` 完成 macOS/CPU/Windows/Server/显示兼容矩阵。
- [ ] `M5-02` 完成代理、网关和恶劣网络矩阵。
- [ ] `M5-03` 8/24 小时长稳和 500 次循环连接。
- [ ] `M5-04` 性能分析并达到批准后的预算。
- [ ] `M5-05` ASan、UBSan、TSan 问题清零或批准例外。
- [ ] `M5-06` 代理解析和 Bridge fuzz 测试达到目标时长。
- [ ] `M5-07` SBOM、许可证、CVE 和 entitlement 审查。
- [ ] `M5-08` 独立渗透测试与问题修复。
- [ ] `M5-09` 隐私审查、日志扫描和数据删除验证。

### 13.7 M6：Beta 与正式发布

- [ ] `M6-01` 建立 internal/beta/stable 更新 feed。
- [ ] `M6-02` Developer ID 签名、公证、staple 和 Gatekeeper 验证。
- [ ] `M6-03` 覆盖新装、覆盖升级、跨 schema 升级和失败恢复。
- [ ] `M6-04` 发布用户指南、管理员指南、隐私说明和第三方许可。
- [ ] `M6-05` 完成受控 Beta，关闭所有发布阻塞问题。
- [ ] `M6-06` 建立崩溃/安全反馈流程与值班责任。
- [ ] `M6-07` 发布 1.0.0，归档可复现构建材料和符号。

---

## 14. 进度跟踪机制

### 14.1 总体仪表板

每周至少更新一次。完成度按通过退出条件的任务数计算，不按主观百分比估计。

| 指标 | 当前值 | 更新时间 |
|---|---:|---|
| 当前里程碑 | M0 技术验证与基线 | 2026-07-29 |
| 总体状态 | 开发中（Universal 2 CI 与 macOS 11 Intel 的 Direct、SOCKS5 真实首帧已通过；全屏悬浮工具栏、macOS 11 图标兼容及 Display Control 显式启用已通过新 CI 和真机启动，等待真实会话交互验收） | 2026-07-29 |
| 已完成任务 | 3 | 2026-07-28 |
| P0 未关闭缺陷 | 0 | 2026-07-28 |
| P1 未关闭缺陷 | 3 | 2026-07-29 |
| 最大风险 | 尚无受控 Windows/RD Gateway/企业代理实验室，无法验证实际 TLS/NLA、代理、网关与重定向行为 | 2026-07-28 |
| 下一门禁 | 新修复版通过双架构 CI 后，在 macOS 11 Intel 验证工具栏图标、全屏小刘海和远端 framebuffer 分辨率确认；HTTP CONNECT 首帧仍需单独验收 | 待新构建及 GUI 验收 |

### 14.2 当前实现快照

本节记录源码进度，不替代第 14.5 节的完成定义。`开发中`项目只有在 Mac 构建、自动化测试和对应人工验收都有证据后才能改为`已完成`。

| 领域 | 已写入源码 | 尚缺的完成证据/实现 |
|---|---|---|
| 工程与依赖 | XcodeGen、SwiftPM、CMake/FreeRDP、Universal 2、归档/公证脚本和 macOS CI；GitHub hosted arm64/x86_64 已分别编译 FreeRDP 3.30.0；运行 `30325083089` 已通过 Xcode 15.4 Universal 2 构建、Swift/AppKit/renderer 测试、签名、依赖闭包和 artifact 上传；产物已在 macOS 11 Intel 创建主窗口 | 完成修复版 Intel 解锁态 onscreen 与连接复验；锁定 OpenSSL 精确版本/来源/哈希；验证全部通道插件；macOS 11 Apple Silicon 启动；Developer ID 签名与公证 |
| 配置与凭据 | SQLite schema v1/WAL、名称/主机/标签搜索、严格 schema、流式输入大小门禁、版本化备份/恢复、数据库/WAL/SHM 批量隔离及失败回滚、导入/迁移回滚失败报告、配置删除事务、凭据唯一所有权、乐观并发、删除/更新竞态防护，三类 Keychain 隔离引用，跨存储事务串行化、临时凭据提示，以及写入/落库/旧引用清理和回滚残留报告；备份剥离全部 Keychain 引用和共享目录授权，恢复清理无引用 Keychain 项；Keychain 查询已移出 AppKit 主线程 | 新 Keychain 后台查询测试通过 CI；macOS Keychain 授权、并发、故障注入与恢复路径人工验收 |
| 网络代理 | Direct、SOCKS5、HTTP/HTTPS CONNECT、仅 loopback 随机端口隧道、代次化停止/失败连接回收、目标/代理/网关统一校验、SOCKS5 域名及 IPv4/IPv6 ATYP、代理端 DNS、Basic、防注入、编码前请求/凭据边界、响应上限、临时代理凭据和 15 秒路径测试；代理握手现于 FreeRDP 启动前完成并将错误返回 UI；macOS 11 上 SOCKS5/HTTP CONNECT 已到达真实 RDP 目标；本地 socket 地址与 NLA 逻辑服务器名已分离 | 新映射通过 CI，并通过应用分别完成 SOCKS5/HTTP CONNECT 的 RDP 登录与首帧；PAC、本机目标 DNS 和企业代理矩阵 |
| RDP 核心 | FreeRDP TLS/NLA、禁用旧 RDP Security、原始证书名、RD Gateway、取消、证书决策桥接及受限终态转换；补齐官方客户端路径要求的静态通道 provider；增加分阶段错误、原生错误名/描述、WinPR/socket 错误和脱敏 FreeRDP 日志；已为 NTLM 构建 WinPR 内置 MD4/RC4 并增加无外部 OpenSSL provider 的已知向量门禁；Direct TLS/NLA 与真实首帧已在 macOS 11 Intel 通过 | 代理完整会话首帧；Windows/RD Gateway 实测；完整认证/错误码矩阵 |
| 会话与输入 | 独立 session ID、旧回调过滤、有限退避、睡眠/网络路径处理、Metal/Core Graphics 自动回退、统一帧边界校验、256 MiB 单帧上限、仅保留最新帧、边界坐标、拖拽 MOVE、两种 Command 模式、原生全屏、悬浮工具栏、RDPEDISP 自适应分辨率和安全序列；Objective-C++/AppKit/renderer 已编译测试 | 帧关闭竞态实测；Windows 端动态分辨率响应与多 DPI 验收；键盘布局与实机性能矩阵 |
| 资源重定向 | FreeRDP 能力开关；用户选目录、安全书签、书签元数据边界和会话级授权生命周期 | 以 3.30.0 头文件完成 rdpdr 设备注册；剪贴板控制器、通道打包和音频/设备实测 |
| 企业管理 | MDM/强制偏好解析；重连、缩放、重定向上限；禁止保存凭据；禁止私有诊断导出；设置 UI 锁定和连接前再次收敛；macOS 11 deployment target 编译已通过 | 真实 MDM 下发、移除与绕过测试；管理员签收 |
| 诊断与安全 | 结构化路由/会话事件、私有字段哈希、敏感字段入口拒绝、诊断预览/清理/脱敏导出，以及文件、配置、凭据和帧缓冲大小门禁 | 崩溃收集策略、安全评审和 fuzz/长稳证据 |
| 静态门禁 | Windows 仓库校验脚本已检查 UTF-8、JSON、plist、依赖固定字段、本地化键/占位符、deployment target 以及显式 AppKit delegate 安装/保活；GitHub arm64/x86_64 Swift 单元测试、AppKit 主窗口生命周期测试和设置页标题变化布局稳定性测试已通过；Objective-C++/renderer 测试已通过；Universal 2 脚本已实际逐 Mach-O/逐架构检查 slice、签名、macOS 11 最低版本、`LC_RPATH` 和运行时依赖闭包 | 静态分析、正式签名/公证门禁、长稳和真实连接测试 |

### 14.3 当前阻塞项

| ID | 阻塞 | 解除条件 | 影响 |
|---|---|---|---|
| BLOCK-003 | Universal 2 OpenSSL 来源尚未锁定 | 固定 arm64/x86_64 OpenSSL 的版本、来源、哈希和许可证，并在 CI 验证 | 构建虽已成功，但供应链不可复现且无法完成许可证/CVE 审计 |
| BLOCK-004 | 无 Windows/RD Gateway/企业代理测试实验室 | 提供受控目标与测试账号，不在仓库或日志中存储秘密 | Direct/NLA、代理、网关、证书和通道不能完成验收 |
| BLOCK-006 | 最终 Bundle Identifier、Keychain service prefix、签名团队和产品标识未确定，当前仍为 `com.example.RemoteDesktop` | 产品/发布负责人分配正式反向域名标识并完成迁移评审 | 不能生成正式签名、公证和可升级的发布包 |
| BLOCK-008 | 尚无可用于验收的 macOS 11 Apple Silicon 实机 | 提供 Big Sur Apple Silicon 设备并运行同一 artifact 的启动、渲染和连接检查 | `M0-03` 和双平台发布兼容性不能关闭 |

### 14.3.1 已解除阻塞

| ID | 解除证据 | 解除日期 |
|---|---|---|
| BLOCK-001 | 已启用 macOS GitHub Actions，并可在 macOS 11.7.10 Intel 实机执行 artifact；启动可见性是否通过由 `M0-02` 单独跟踪 | 2026-07-27 |
| BLOCK-002 | CI 已下载并在 arm64/x86_64 runner 上编译 FreeRDP 3.30.0 | 2026-07-27 |
| BLOCK-005 | 公开仓库及 CI 已能访问 GitHub/上游；OpenSSL 的精确供应链锁定继续由 `BLOCK-003` 跟踪 | 2026-07-27 |
| BLOCK-007 | 仓库已改为公开，[macOS #24](https://github.com/tantanwu/AlstarsRDP/actions/runs/30288609403) 全部成功 | 2026-07-27 |

### 14.3.2 构建与实机证据

- 回归基线：提交 `d9348c2`、运行 [30288609403](https://github.com/tantanwu/AlstarsRDP/actions/runs/30288609403) 的产物可保持进程运行 12 秒，但 Quartz 验证为 `windows=[]`。该结果不能证明应用成功启动，原 0.2.5 结论已撤回。
- 根因：项目没有 storyboard/MainMenu.xib，却直接在 `AppDelegate` 上使用 `@main`；`NSApplicationMain` 进入事件循环后未实例化并安装 delegate，`applicationDidFinishLaunching` 没有执行。
- 修复：提交 `9037bb0` 增加显式 AppKit 入口，安装并保活 `AppDelegate`，显式展示主窗口并处理 Dock reopen；提交 `6839085` 修复 Swift 6 主 actor 测试隔离。
- 成功构建：GitHub Actions 运行 [30316764662](https://github.com/tantanwu/AlstarsRDP/actions/runs/30316764662) 全部通过，包含 AppKit delegate/主窗口生命周期断言、Universal 2 构建、ad-hoc 签名和依赖闭包门禁。
- 修复产物：`AlstarsRDP-macOS11-Universal2-unsigned`，Actions artifact ID `8672486175`，Actions SHA-256 `7a4516faa5a628525197177eba809717c94b41bae51a8ddbca21a1dc8f00b7fa`；内层 ZIP SHA-256 `ad9fa252d68a5a336aed70b957bcefd995e99dad3f7e7d85281b020e8267d2e0`。
- macOS 11.7.10 Intel 实机：`codesign --verify --deep --strict` 通过，主程序同时包含 x86_64/arm64，LaunchServices 重新注册后可正常启动；Quartz 检测到一个 layer 0、alpha 1.0、`900x608` 主窗口。验证时桌面处于锁屏状态，前台为 `loginwindow`，因此 `kCGWindowIsOnscreen=false`；解锁态 onscreen 证据仍待补齐。

### 14.3.3 已修复启动缺陷

| ID | 等级 | 现象 | 根因 | 修复与回归保护 | 状态 |
|---|---:|---|---|---|---|
| BUG-001 | P1 | 双击应用后进程存在，但没有任何界面或报错 | 无 storyboard 的程序化 AppKit 应用未显式安装并保活 `AppDelegate` | `9037bb0`、`6839085`；新增 delegate、主窗口数量与 `isVisible` 生命周期测试，并在 Windows 仓库门禁检查显式入口 | 已修复，待解锁态真机复验 |
| BUG-002 | P1 | 保存后目标 `3389` 变成 `3`、代理 `7897` 变成 `7`，测试连接始终失败 | `NSTextField.integerValue` 对本地化分组字符串 `3,389`/`7,897` 只解析逗号前前缀 | `dbbb3cc` 改用无分组的字符串读写和纯数字严格解析；新增截断回归测试；真机数据库已备份并定向修复为 `3389`/`7897` | 已修复，CI 与数据库完整性验证通过 |
| BUG-003 | P1 | 代理或 RDP 失败后会话窗口只有空白画面，无法判断阶段和错误 | 本地 listener 在真实代理握手前返回，后台握手错误被隧道吞掉；状态仅在紧凑工具栏显示 | `dbbb3cc` 在建立 listener 前完成代理握手并直接抛错；新增中央状态/错误/重试层和深色等待画布，仅在帧校验通过后隐藏状态层 | 已修复，待应用内 RDP 首帧验收 |
| BUG-004 | P1 | Direct 连接持续失败并显示 `0x00020001` | 自建 `freerdp_new`/`freerdp_context_new` 路径在加载静态通道前未执行官方客户端路径的 `freerdp_register_addin_provider`，导致 PreConnect 在网络、TLS/NLA 和认证前失败 | `74d6ac4` 在 PreConnect 加载 add-ins 前线程安全注册 `freerdp_channels_load_static_addin_entry`；增加分阶段错误摘要和分类测试 | 代码与 CI 已修复，待 macOS 11 真机连接/首帧复验 |
| BUG-005 | P2 | 设置页每次测试连接后，Network 页文字向右下角累计移动 | `NSTabViewItem` 直接承载带 `edgeInsets` 的可变尺寸 `NSStackView`，测试按钮标题变化和 sheet 关闭反复触发 tab 内容重排 | `74d6ac4` 使用稳定容器和顶部/左侧 Auto Layout 约束，固定测试按钮 alignment width；`7e7a9d9` 增加连续标题变化的 AppKit 坐标稳定性测试 | 已修复并通过 CI，待 macOS 11 真机连续点击复验 |
| BUG-006 | P1 | 连接真实 Windows 目标时持续显示 `0x0002000D` | 静态 OpenSSL 3 构建未携带 legacy provider；NLA/NTLM 初始化 MD4 时失败并返回 `SEC_E_NO_CREDENTIALS`，外层再覆盖为通用连接错误 | `848396c` 构建 WinPR 内置 MD4/RC4；CI `30332296837` 双架构通过；macOS 11 Intel 已完成 Direct TLS/NLA 并显示真实首帧 | 已修复并完成 Direct 真机验收 |
| BUG-007 | P1 | 路径测试成功，但通过 SOCKS5/HTTP CONNECT 启动完整 RDP 会话仍失败 | 第一根因是 loopback 地址污染 NLA/SPN 身份；修复后真机原生日志进一步定位到第二根因：`newConnectionHandler` 在 accepted `NWConnection` 启动并进入 `.ready` 前立即取消 listener，导致 FreeRDP 对 loopback 的非阻塞 connect 被提前拆除 | 保持 `ServerHostname=127.0.0.1`、原始主机写入 `UserSpecifiedServerName`/`CertificateName`；listener 延长到首个 downstream socket 达到 `.ready` 后再取消；增加身份映射、真实 TCP 双向 relay、单连接和停止/重启回归测试 | 已修复；SOCKS5 完整会话由用户真机确认成功，HTTP CONNECT 首帧待单独验收 |
| BUG-008 | P1 | 修改分辨率后无法保存，重新打开仍为旧值 | 宽高继续使用 `NSTextField.integerValue` 和 clamping 转换，未采用端口修复后的严格无分组字符串路径 | 加载使用无分组十进制字符串；保存严格拒绝分组、小数、负数、空值、越界和超像素上限输入；增加解析回归测试 | 已修复；CI 通过，macOS 11 真机保存、关闭并重开编辑器验证通过 |
| BUG-009 | P2 | 打开设置或连接时，Keychain 授权查询可能阻塞 AppKit 主线程 | 同步 `SecItemCopyMatching` 从主 actor 调用 | 通过 `Task.detached` 后台读取，主线程仅消费结果；增加线程回归测试 | 已修复；双架构 CI 与 macOS 11 后台线程测试通过 |
| BUG-010 | P1 | 分辨率设置不直观，远程窗口不能进入全屏，“动态分辨率”不会随本地窗口变化 | 配置只在连接前设置 `DynamicResolutionUpdate` 布尔值，没有接入 Display Control 通道、发送 Monitor Layout 更新或监听窗口事件；创建窗口时错误地预置 `.fullScreen` 状态位，且没有标准全屏菜单行为 | 接入 RDPEDISP Display Control；按画布 backing pixels、DPI 和协议边界计算尺寸，拖动去抖并在屏幕/全屏变化后立即同步；改用 `.fullScreenPrimary` 和标准快捷键；显示设置增加常用分辨率与“跟随窗口”模式 | 代码、双架构 CI、Universal 2 产物和 macOS 11 启动验证已完成；真实 RDP 窗口拖动与全屏效果待用户验收 |
| BUG-011 | P1 | macOS 11 会话窗口的断开/全屏图标不可见；全屏顶部仍被整条工具栏占用；跟随窗口看不到 Windows 分辨率变化 | 图标和刘海兼容问题已分别修复；协议侧先缺少 RDPGFX GDI 初始化，修复后真机日志进一步确认目标服务器从未建立 Display Control (`disp`) 通道，所有在线布局请求均在本地因通道未激活而拒绝 | 初始化 RDPGFX 并监听服务器尺寸；显式登记 `disp`/`rdpgfx` 动态通道并记录加载状态；支持 RDPEDISP 时在线调整，不支持时对最终画布尺寸执行带激活宽限、防抖和限频的受控重连 | 图标、刘海、RDPGFX 版本已通过 CI 和 macOS 11 部署；动态通道显式登记与旧服务器重连降级待新 CI 和真实 Windows 验收，不能提前关闭 |
| BUG-012 | P1 | Direct 正常，但同一目标经本机 Clash SOCKS5 返回 `0x00020006` | 应用外最小探针确认 SOCKS5 握手成功后，上游在 RDP 响应前主动 EOF；Clash 调试日志确认目标命中 `Match` 并经当前新加坡代理节点转发，该节点不提供可用的 3389/RDP TCP 路径 | 路径测试从“代理握手成功”升级为验证真实 X.224/RDP 协商响应；路径测试和正式会话都对代理早期网络失败给出节点可能阻止 3389/RDP 的明确提示；实际连接需更换支持任意 TCP 的节点、专用 SOCKS/SSH 或 RD Gateway | 应用误报已修复并通过全套 CI；当前 Clash 节点兼容性属于外部阻塞，切换节点后复验 |

### 14.3.4 代理与空白会话修复证据

- 配置取证：真机 profile 保存为目标端口 `3`、SOCKS5 `127.0.0.1:7`；两端口均不可达，而同一目标 `3389` 可达。
- 代理取证：Clash Verge 生效配置为 mixed port `7897`；SOCKS5 和 HTTP CONNECT 均已从该端口到达真实 Windows 目标 `3389`。控制端口 `33331` 不是代理入口。
- 配置修复：停止应用后用 SQLite 在线备份保存修复前数据库；仅当 profile 仍匹配 `3/7` 时定向更新为 `3389/7897`，更新数严格为 1；修复前备份和修复后数据库的 `PRAGMA integrity_check` 均为 `ok`，未读取或修改 Keychain 密码。
- 成功构建：提交 `dbbb3cc`，GitHub Actions 运行 [30321658257](https://github.com/tantanwu/AlstarsRDP/actions/runs/30321658257) 全部通过；artifact ID `8674261915`，Actions SHA-256 `b2a93aa71d0a6067ac603337f149bb444c9d7423e962b2aae98e14686002a4a2`，内层 ZIP SHA-256 `7ba0dcf33bbeb6fff6ad3bcb867a26a3f50fd86ba8a6fed8ac0ff8eef30b5b18`。
- 真机部署：修复版通过严格 codesign 校验并包含 x86_64/arm64；已部署到 macOS 11.7.10 Intel，主窗口创建成功。应用内 TLS/NLA 登录和首帧仍需在 GUI 中使用 Keychain 凭据触发后验收。

### 14.3.5 FreeRDP 预连接与设置页布局修复证据

- 错误定义：锁定的 FreeRDP 3.30.0 将 `0x00020001` 定义为 `FREERDP_ERROR_PRE_CONNECT_FAILED`；失败点早于 DNS、代理、TLS/NLA 和 Windows 凭据校验。
- 根因与修复：`RDPSession.mm` 直接创建 FreeRDP context，未执行 `freerdp_client_context_new` 中的静态通道 provider 注册。提交 `74d6ac4` 在 `freerdp_client_load_addins` 前一次性、线程安全地注册 provider，并保留注册失败检查。
- 布局修复：Network 页 stack 改为由稳定 `NSView` 容器承载并固定顶部/左侧位置；测试按钮使用 120 pt alignment width。回归测试连续切换四次按钮标题，断言按钮 alignment width 与页面 stack 坐标不变。
- 自动化证据：首次运行 `30323866357` 的 Universal 2 应用编译成功，新增测试因把 AppKit frame（包含左右 alignment inset）误当 alignment rect 而失败；提交 `7e7a9d9` 修正断言。GitHub Actions 运行 [30325083089](https://github.com/tantanwu/AlstarsRDP/actions/runs/30325083089) 随后全部通过，包括双架构 Swift 测试、FreeRDP 构建、Universal 2 应用构建、AppKit/renderer 测试、ad-hoc 签名、依赖闭包、打包和仓库校验。
- 构建产物：`AlstarsRDP-macOS11-Universal2-unsigned`，Actions artifact ID `8675411822`，Actions SHA-256 `08470ac85b9ec3db7004f042ff3f45b463b32be69c1f2657180b25f2da61ceff`。内层 ZIP 哈希、macOS 11 真机 `0x00020001` 消失、RDP 首帧和设置页连续点击仍待新产物下载安装后确认。

### 14.3.6 NLA/NTLM 加密初始化修复证据

- 网络与协议取证：macOS 11 真机保存的 `Etsy` 配置使用 Direct 路由；目标 TCP `3389`、X.224 协商和 TLS 1.2 握手均成功，服务端选择 `HYBRID_EX`，因此 `0x0002000D` 不是目标不可达或代理失败。
- 原生诊断：提交 `efb442c` 捕获 FreeRDP 错误名/描述、WinPR/socket 错误和 ERROR 级原生日志，并对用户名、密码脱敏。GitHub Actions 运行 [30330201522](https://github.com/tantanwu/AlstarsRDP/actions/runs/30330201522) 全绿；真机日志明确记录 `Failed to initialize digest md4` 与 `InitializeSecurityContext status SEC_E_NO_CREDENTIALS [0x8009030e]`。
- 根因：FreeRDP/WinPR 链接静态 OpenSSL 3，但应用包没有 OpenSSL legacy provider。NTLM 所需的 MD4 和 RC4 不应依赖构建机 Homebrew provider 路径。
- 修复与门禁：提交 `848396c` 显式启用 FreeRDP 3.30.0 的 `WITH_INTERNAL_MD4` 和 `WITH_INTERNAL_RC4`；逐架构检查安装后的 WinPR 配置宏，并在 `OPENSSL_MODULES` 指向空目录时运行 MD4、RC4 标准向量。
- 自动化与真机证据：GitHub Actions `30332296837` 全绿；产物在 macOS 11.7.10 Intel 通过严格签名、Universal 2 和最低系统版本检查，Direct TLS/NLA 成功并收到真实远程首帧，不再出现 MD4 或 `SEC_E_NO_CREDENTIALS` 错误。

### 14.3.7 代理服务器身份与分辨率持久化修复

- FreeRDP 3.30.0 取证：`transport.c` 使用 `ServerHostname` 建立 TCP/TLS socket；`freerdp_settings_get_server_name` 优先返回 `UserSpecifiedServerName`；`nla.c` 用该值建立 `TERMSRV/<hostname>` CredSSP 身份；`CertificateName` 独立覆盖证书名称验证。
- 代理修复：loopback 继续作为唯一 socket 目标，原始 Windows 主机作为 `UserSpecifiedServerName`，原始证书身份继续作为 `CertificateName`。`TargetNetAddress` 已确认仅用于服务端重定向，不用于该隧道场景。
- 分辨率修复：宽高统一使用纯 ASCII 十进制读写，范围为宽至少 320、高至少 200、单边不超过 16384、总像素不超过 67,108,864；非法输入不再被截断或 clamp 后静默保存。
- Keychain 响应性：配置编辑器与会话启动的 Keychain 读取移至后台执行，避免授权交互冻结 AppKit 主线程；不改变 Keychain service、访问控制或凭据存储格式。
- 自动化与产物：提交 `15b6239` 的 GitHub Actions `30340814145` 全绿，包含双架构 Swift、FreeRDP、Universal 2、AppKit/Objective-C++、Keychain 后台线程测试；artifact ID `8681011299`，Actions SHA-256 `1b5be4d43d42e9cb514f57fabae4058c8eb8cde2eae39300b175c54247c6ea33`，内层 ZIP SHA-256 `251c67e83df18b52ee59d6fa6c99ac409d55fcfcafcb11879ca42d51c0751a4a`。
- 真机持久化验收：产物在 macOS 11.7.10 Intel 通过严格 codesign、x86_64/arm64 和最低系统 11.0 检查；分辨率由 `1920x1080` 改为 `1600x900`，保存、关闭编辑器并重开后保持不变，随后已恢复原值 `1920x1080` 并由数据库确认。BUG-008 完成。
- 代理第二根因：SOCKS5 握手成功后，完整 RDP 仍在本机 `127.0.0.1` 随机端口的 TCP 接入阶段失败；桥接层脱敏日志记录 `Couldn't get socket ip address`、`ConnectLayer 127.0.0.1:<port> failed`，失败早于 TLS/NLA。代码审计确认 `LoopbackTunnel.accept` 在 downstream `start`/`.ready` 前调用 `listener.cancel()`。
- listener 修复：提交 `34ab7df` 将首个 downstream 被认领后的 listener 保留到该 socket 达到 `.ready`，同时继续拒绝其他连接；正常、失败、任务取消和竞争路径均取消 listener 并回收上下游连接。新增真实本地 TCP 回显集成测试覆盖 prefetched data、双向转发、单连接约束以及 stop 后重新启动。提交 `9f0bbda` 为 Network.framework 的拒绝连接自动重试增加测试取消边界，避免负向断言无限等待。
- listener 自动化证据：GitHub Actions [30344220649](https://github.com/tantanwu/AlstarsRDP/actions/runs/30344220649) 全绿，新增真实 socket relay 测试在 arm64/x86_64 均通过；artifact ID `8682348091`，官方 Actions SHA-256 `194c222fea1161d23c9f3cd9a8d79c7dcee07d1a43d339a38fc2ce51c1ecfc76`，内层 ZIP SHA-256 `a81895320438a298a3f6ce07b9e1386e1e8ffc229adc53d683a8750b0874821c`。
- listener 真机部署：新产物部署到 `/Users/jerry/AlstarsRDP-validation/run-30344220649/unpacked/RemoteDesktop.app`，通过严格 codesign、x86_64/arm64 和最低系统 11.0 检查；应用启动、现有 SOCKS5 profile 加载和会话窗口创建成功。完整首帧当前停在 macOS SecurityAgent 对目标 Keychain 项的人工授权，不读取或代填登录密码。
- 待验收：macOS 11 Intel 上 SOCKS5、HTTP CONNECT 与 Direct 完整 RDP 首帧；连续代理路径测试布局不漂移。

### 14.3.8 自适应分辨率与全屏修复

- 用户验收反馈：部署运行 `30344220649` 后，SOCKS5 代理完整会话可以连接；分辨率持久化问题已消失。后续发现显示模式不够直观、会话窗口无法正常进入 macOS 全屏，且远端桌面尺寸不会随本地窗口变化。
- 协议根因：动态分辨率需要 `SupportDisplayControl` 将 `disp` 加入通道加载列表，并由 `DynamicResolutionUpdate` 开启客户端动态更新策略；应用还必须订阅 `Microsoft::Windows::RDS::DisplayControl` 的连接/断开事件，在服务器发送 Display Control Caps 后调用 `SendMonitorLayout`。旧桥接未实现该生命周期。
- 自适应策略：动态模式连接前使用当前画布 backing pixels 作为初始桌面；Retina backing scale 映射到 DesktopScaleFactor；宽度取偶数，单边限制在 RDPEDISP 的 200–8192 范围，总像素不超过 64 Mi；窗口拖动使用 500 ms 去抖，拖动结束、屏幕变化、backing scale 变化以及进入/退出全屏立即同步。同步任务使用单调代次避免取消竞态，Display Control 通道重新激活后强制重发当前布局。
- 设置体验：显示模式区分“缩放固定分辨率”“固定分辨率原始大小”“跟随窗口”；固定模式提供 1280x720 至 3840x2160 常见预设和自定义输入；跟随窗口时禁用无效的固定宽高输入，保存不再被失效输入阻断。
- 全屏修复：创建窗口时不再预置 `.fullScreen` 状态位，改用 `.fullScreenPrimary` 原生行为；工具栏按钮与“窗口”菜单均调用 `toggleFullScreen`，并提供 Control-Command-F。
- 竞态修复：Display Control 通道重新激活时清除旧布局缓存并强制重发；自适应任务使用单调代次，防止被取消的旧任务覆盖新任务状态。全屏快捷键在安装 `windowsMenu` 后设置，避免新版 AppKit 自动改写。
- CI 证据：提交 `8c5813e` 的 GitHub Actions `30375985139` 全绿；arm64/x86_64 Swift 测试、arm64/x86_64 FreeRDP、Universal 2 Release 构建以及 118 项 AppKit/桥接/渲染测试全部通过。
- 产物证据：GitHub artifact `AlstarsRDP-macOS11-Universal2-unsigned` SHA-256 为 `d89c440cfea549fa1921a50da5e4d315c3458710243073e25c831b8b2831fb1d`，内部应用压缩包 SHA-256 为 `78819c629a6d7fa41cd1a021f73a195ff333cde44712186955143d6838805ba7`。严格 codesign 校验通过，主程序同时包含 x86_64/arm64，两个 slice 的最低系统均为 macOS 11.0。
- macOS 11 部署：新产物部署到 `/Users/jerry/AlstarsRDP-validation/run-30375985139/unpacked/RemoteDesktop.app`，在 macOS 11.7.10 Intel 真机成功启动且统一日志无应用错误；未覆盖上一可用版本。
- 待用户验收：选择“跟随窗口”后连接真实 Windows，确认窗口拖动、进入/退出全屏时远端实际分辨率变化；如有 Retina/非 Retina 双屏，确认跨屏后 DPI 与分辨率同步；HTTP CONNECT 首帧仍按 BUG-007 单独验收。

### 14.3.9 全屏悬浮工具栏与远端分辨率确认

- macOS 11 图标取证：`rectangle.portrait.and.arrow.right` 和 `rectangle.inset.filled` 在 macOS 11.7.10 返回 `nil`，旧代码随后构造空 `NSImage`，所以按钮可点击但没有可见内容；改用已在 macOS 11 验证的 `xmark.circle`、`arrow.up.left.and.arrow.down.right`，并保留 AppKit 模板图片兜底。
- 全屏布局：普通窗口继续保留完整顶部工具栏；进入原生全屏后画布直接贴合 content 顶部，工具栏缩为顶部中央 `72x8` 触发条，鼠标进入展开为 `336x42`，移出 300 ms 后收起，不再为顶部整条区域预留画布空间。
- Display Control 取证：FreeRDP 3.30.0 官方命令行 `/dynamic-resolution` 同时设置 `FreeRDP_SupportDisplayControl` 与 `FreeRDP_DynamicResolutionUpdate`；库初始化时前者默认也为 `true`，所以旧代码缺少显式赋值不是已证实的唯一根因。桥接层现显式保持两者一致，以固定配置契约；最终仍以远端帧尺寸确认作为是否生效的判据。
- 可观测性：工具栏显示远端实际 framebuffer 尺寸；新布局发送后显示“当前尺寸 > 请求尺寸”，收到目标尺寸帧后确认；1.5 秒无确认时最多重试三次，并以 `RDP_DISPLAY_CONTROL_ACTIVE`、`RDP_RESIZE_LAYOUT_SENT`、`RDP_RESIZE_CONFIRMED`、`RDP_RESIZE_RETRY`、`RDP_RESIZE_NOT_CONFIRMED` 等代码写入诊断。
- 自动化证据：提交 `9ed0c53` 的首次运行 [30405990292](https://github.com/tantanwu/AlstarsRDP/actions/runs/30405990292) 已通过双架构 Swift/FreeRDP 和 Universal 2 Release 编译，但新增按钮测试错误地比较 AppKit bezel frame `30x31` 与 alignment rect `28x28`，因此 118 项测试中有 2 个断言失败。提交 `27396da` 改为验证 alignment rect 后，运行 [30406492290](https://github.com/tantanwu/AlstarsRDP/actions/runs/30406492290) 全绿：118 项 AppKit/桥接/渲染测试、ad-hoc 签名、双架构依赖闭包、打包和仓库校验全部通过。
- 产物证据：artifact ID `8706804838`，GitHub SHA-256 `af740e38afc8012d9da2ea96cd3e51758e8c61b25dc7daad52d0af8491874ad6`，内层 ZIP SHA-256 `4f2d87d6fa55e66a191544578f60b0c5cd183f4a7256a7dd00419e84e62b2022`；严格 codesign 通过，主程序包含 `x86_64 arm64`，两个 slice 最低系统均为 macOS 11.0。
- 真机部署：新产物部署到 `/Users/jerry/AlstarsRDP-validation/run-30406492290/unpacked/RemoteDesktop.app`，未覆盖旧版；macOS 11.7.10 Intel 上应用保持运行，System Events 确认主窗口可见、标题为“远程桌面连接”、尺寸 `900x608`，统一日志未发现应用 error。
- 当前状态：构建和基础启动已完成；断开/全屏图标、全屏小刘海悬停收起以及真实 Windows framebuffer 尺寸变化仍需连接会话后人工验收，BUG-011 不能提前标记完成。

### 14.3.10 刘海操作区与服务器桌面尺寸确认修复

- 用户复验：运行 `30406492290` 产物时，全屏刘海展开后仍只显示分辨率，四个操作按钮不可见；“跟随窗口”仅能从远程浏览器的响应式重排观察到变化，无法证明 Windows 已实际接受目标桌面尺寸。因此 BUG-011 继续保持未完成。
- 刘海根因与修复：旧布局把四个按钮、可伸缩空白和具有 required hugging 的尺寸标签放在同一个 `NSStackView`，macOS 11 下按钮可能被压缩并被容器裁剪。操作按钮现使用独立固定宽度 stack，尺寸标签独立靠右约束；按钮固定 `28x28`、required 抗压缩、白色模板 tint 和可见背景；全屏展开尺寸调整为 `388x42`，收起仍为顶部中央 `72x8`。
- 协议确认根因与修复：旧桥接在 `SendMonitorLayout` 返回成功后立即覆盖 `FreeRDP_DesktopWidth/Height` 和缩放设置，这不代表服务器已接受布局，并可能制造假确认。现已删除本地覆盖；仅在服务器触发 FreeRDP `DesktopResize`、且 `gdi_resize` 成功后回调 Swift 层，将服务器报告尺寸作为唯一协议确认。渲染帧尺寸继续用于画面检查，但不再确认动态分辨率请求。
- 节流与诊断：所有 Monitor Layout 请求额外保证至少间隔 500 ms；服务器精确应用、返回不同尺寸或多次未确认分别记录 `RDP_RESIZE_CONFIRMED`、`RDP_RESIZE_SERVER_ADJUSTED` 和 `RDP_RESIZE_NOT_CONFIRMED`。刘海尺寸标签优先显示服务器确认尺寸，并在请求待确认时显示“当前尺寸 > 请求尺寸”。
- 自动化状态：已补充四个按钮在展开刘海内可见、未裁剪、与最大长度尺寸标签不重叠的 AppKit 回归断言。提交 `ad7dc7a` 的 GitHub Actions [30411709387](https://github.com/tantanwu/AlstarsRDP/actions/runs/30411709387) 全绿，双架构 Swift/FreeRDP、Universal 2 Release、AppKit/桥接/渲染测试、ad-hoc 签名及打包门禁均通过；Windows 工作区动态调整仍需真实会话复验后才能关闭 BUG-011。
- 构建产物：artifact ID `8708704612`；GitHub 外层 SHA-256 为 `d0055ebc083ddba758ea8f5bba764197b5b45c53264666389d5da2eaa42e0c1b`，内层应用 ZIP SHA-256 为 `4ac2b8a57215a7fb36287435bea29820336d3546bfb6a91901d54f46e7317231`。下载文件与 GitHub 摘要一致。
- macOS 11 部署：产物已部署到 `/Users/jerry/AlstarsRDP-validation/run-30411709387/unpacked/RemoteDesktop.app`，未覆盖或终止旧版本。macOS 11.7.10 Intel 上严格 codesign、`x86_64 arm64`、最低系统 11.0、进程启动和无 error 级统一日志均通过；辅助功能树确认会话窗口中的断开、重连、全屏和 Ctrl+Alt+Delete 四个按钮均存在、标签正确且具有非零尺寸。全屏悬停和真实 Windows `DesktopResize` 仍待用户复验。
- 行为边界：RDP Display Control 调整的是 Windows 远程桌面/工作区尺寸。最大化窗口和响应式应用会随工作区变化；普通浮动窗口按 Windows 既有行为保持自身窗口大小，客户端不能强制所有远程应用自动放大或重新布局。

### 14.3.11 RDPGFX 图形管线与动态分辨率闭环修复

- 用户复验：运行 `30411709387` 产物后，改变本地窗口大小、进入或退出全屏时 Windows 桌面分辨率均没有变化。真机配置数据库确认当前 profile 的 `scaleMode` 为 `dynamicResolution`，固定宽高为 `1920x1080`，排除“跟随窗口未保存或未启用”。BUG-011 继续保持未完成。
- 已证实协议缺口：桥接显式启用了 `FreeRDP_SupportGraphicsPipeline`，但只接入 Display Control (`disp`) 动态通道，没有在 `Microsoft::Windows::RDS::Graphics` (`rdpgfx`) 通道连接时调用 `gdi_graphics_pipeline_init`。服务器返回 `ResetGraphics` PDU 时没有安装 GDI `ResetGraphics` 回调，因此新的 `width/height` 无法更新 settings、重建 framebuffer 或触发应用的 `DesktopResize`。
- 修复实现：桥接同时处理 `DISP_DVC_CHANNEL_NAME` 与 `RDPGFX_DVC_CHANNEL_NAME`；RDPGFX 连接后显式绑定 GDI 管线，断开和 `PostDisconnect` 时幂等释放；订阅 FreeRDP `GraphicsReset` PubSub 事件，并与经典 `DesktopResize` 统一去重后向 Swift 层发布服务器实际桌面尺寸。
- 生命周期依据：FreeRDP 3.30.0 在 `PostConnect` 的 `gdi_init` 之后才执行通道 post-connect，因此 RDPGFX 连接时 GDI 已可用；`rdpgfx_recv_reset_graphics_pdu` 先调用 GDI `ResetGraphics`，随后发布 `GraphicsResetEventArgs`。自定义 `RDPAppContext` 不能直接转发官方 `freerdp_client_OnChannelConnectedEventHandler`，因为该函数会把 context 强转为更大的 `rdpClientContext`，所以本项目只显式接入所需 RDPGFX 生命周期。
- 诊断闭环：使用 `[RDPDisplay]` 统一日志持久记录 Display Control 连接、能力激活、布局发送状态、RDPGFX 初始化结果和服务器返回尺寸。新构建真机复验时必须看到 `Display Control activated`、`layout ... send status=0`，并最终看到 `server desktop DesktopResize` 或 `server desktop GraphicsReset`；缺少任一环节均不能将请求视为生效。
- 自动化状态：提交 `d14c4c6` 的 GitHub Actions [30415028733](https://github.com/tantanwu/AlstarsRDP/actions/runs/30415028733) 全绿，耗时 4 分 28 秒；两组 Swift 测试、arm64/x86_64 FreeRDP、Universal 2 应用、AppKit/桥接/渲染测试、ad-hoc 签名、依赖闭包和打包门禁全部通过。仅有 GitHub artifact action 的 Node.js 20 弃用警告，与应用代码无关。
- 构建产物：artifact ID `8709898446`；GitHub 外层 ZIP SHA-256 为 `2a748d4e486b79f1bf27d11ebe1b6661a534e1d09449cab8c8da461c7710e302`，内层应用 ZIP SHA-256 为 `688b5986972e159b600498ae23cb1d9fc87983192ad9ed6f4be174de6eb9e221`，下载后双重校验一致。
- macOS 11 部署：应用已部署到 `/Users/jerry/AlstarsRDP-validation/run-30415028733/unpacked/RemoteDesktop.app`，未覆盖旧目录或主动终止旧会话。macOS 11.7.10 Intel 上严格 codesign、主程序和 RDPBridge 的 `x86_64 arm64`、最低系统 11.0 均通过；新进程从该路径启动并保持运行，System Events 确认主窗口可见且标题为“远程桌面连接”，启动后三分钟内无 error 级统一日志。
- 当前状态：代码、CI、产物校验和 macOS 11 基础启动已完成；真实 Windows 会话中窗口拖动、进入/退出全屏及 `[RDPDisplay]` 服务器尺寸确认仍待复验，BUG-011 保持未完成。

### 14.3.12 Display Control 缺失与旧服务器分辨率降级

- 用户复验与画面证据：在 `30415028733` 产物中把本地会话窗口从横向小窗口改为接近全屏后，工具栏报告的远端尺寸始终为 `1180x712`；画面只从上下黑边变成左右黑边，证明客户端在缩放同一张远端 framebuffer，而不是 Windows 工作区发生变化。
- 真机协议日志：进程 `48099` 在 09:59 至 10:00 的每次窗口/全屏请求均记录 `[RDPDisplay] layout rejected locally: Display Control is unavailable or inactive`，没有任何 `Display Control channel connected`、capabilities、activated 或 layout send 事件。该会话也没有 RDPGFX 连接事件，说明服务器使用经典图形路径；Metal 无设备日志由 Core Graphics 自动回退处理，与分辨率失败无关。
- 根因边界：初次连接得到的远端 `1180x712` 与当时画布一致，证明连接前 `DesktopWidth/Height` 生效。失败仅限连接后的在线调整：目标 RDP 服务没有建立 RDPEDISP 通道，因此没有协议命令可在当前连接中提交 Monitor Layout。
- 通道加固：在通用 add-in 加载前显式把 `disp` 和 `rdpgfx` 加入 FreeRDP 动态通道集合，重复项由 FreeRDP collection 去重；新增日志记录 add-in 结果、两条通道是否排队和动态通道总数，从而区分“客户端未登记”与“服务器未建立”。
- 兼容降级：RDPEDISP 激活时继续使用无缝 `SendMonitorLayout`；未激活时仅在已收到远端首帧、目标画布尺寸不同且窗口稳定后执行一次受控重连。策略包含 2.5 秒通道激活宽限、750 ms 最终尺寸防抖和 4 秒最小重连间隔，并复用现有内存/Keychain 凭据与代理路线，不在拖动过程中连续断线。
- 自动化覆盖：新增激活宽限、重连限频、未知远端尺寸不重连、相同尺寸不重连和尺寸不同时启用降级的单元测试；新增诊断码 `RDP_RESIZE_RECONNECT_FALLBACK` 和中文状态提示。
- 自动化状态：提交 `ba0867f` 的 GitHub Actions [30416244604](https://github.com/tantanwu/AlstarsRDP/actions/runs/30416244604) 全绿；双架构 Swift 测试、arm64/x86_64 FreeRDP、Universal 2 Release、AppKit/renderer 测试、ad-hoc 签名、依赖闭包、打包和仓库校验全部通过。
- 构建产物：artifact ID `8710313921`，大小 `18,887,812` bytes，GitHub SHA-256 为 `7e39802e2e309f312ef7b4bcfb5a7a76f29df666cc46f1ad86d022e56e31b3d9`。
- 当前状态：代码、自动化测试与 GitHub 构建已完成；产物下载双重校验、macOS 11 部署及真实 Windows 重连后尺寸变化待完成，BUG-011 保持未完成。
- 代理回归取证：macOS 11 真机对 `129.226.89.229:3389` 发送同一个最小 X.224 请求，Direct 在等待 3 秒后仍返回合法 19-byte RDP 协商响应；SOCKS5 `127.0.0.1:7897` 返回成功握手后在 1 秒内 EOF，立即发送请求同样无任何 RDP 响应。该探针未经过应用代码，排除 loopback relay、FreeRDP、账号、证书、NLA 和显示通道。
- Clash 取证：mihomo `v1.19.21`、`rule` 模式、mixed port `7897`；临时启用 debug 后记录目标命中 `Match`，出站链为“良心云/新加坡专线01”，随后立即关闭。日志级别已恢复 `warning`，未改动节点、规则或凭据。
- 路径测试加固：SOCKS5/HTTP CONNECT/Direct 探针在 TCP 或代理握手后继续验证真实 TPKT/X.224 Connection Confirm；代理提前关闭时提示节点可能阻止 TCP 3389/RDP，避免将“隧道建立”误报为“RDP 路径可用”。正式会话的代理专用错误摘要同步覆盖 `0x00020006`/`0x00020007`/`0x0002000D`，Direct 和认证错误保持原分类。新增合法响应、非 RDP 响应、截断响应、错误 PDU 类型和路由分类测试。
- 代理诊断构建：提交 `b51aeda` 的 GitHub Actions [30418320065](https://github.com/tantanwu/AlstarsRDP/actions/runs/30418320065) 全绿；双架构 Swift、arm64/x86_64 FreeRDP、Universal 2 Release、AppKit/renderer、ad-hoc 签名、依赖闭包、打包及仓库门禁全部通过。应用 artifact ID `8711016451`，大小 `18,905,338` bytes，GitHub SHA-256 为 `7e434ae943c9955babc373e959c98195ab17ca208a215d3bc058e478c9e9115f`；匿名 API 下载返回 `401`，待登录 GitHub 后下载并完成 macOS 11 UI 复验。

### 14.4 每周状态模板

```markdown
## 周报 YYYY-Www（YYYY-MM-DD）

状态：绿 / 黄 / 红
当前里程碑：M?

本周完成：
- [REQ/TASK-ID] 可验证结果和证据链接

下周计划：
- [REQ/TASK-ID] 预期交付物

阻塞项：
- [BLOCK-ID] 责任人 / 需要的决定 / 最晚日期

指标：
- 构建：
- 测试：通过 / 失败 / 跳过
- P0/P1 缺陷：
- 性能/稳定性变化：

范围或日期变化：
- 变化、原因、批准人和关联 ADR
```

### 14.5 单项任务完成定义

任务只有同时满足以下条件才标记完成：

- 需求与验收标准已明确，无未记录的行为差异。
- 代码已评审并合入主干。
- 自动化测试已添加并通过；人工测试有证据。
- 安全、隐私、兼容或性能影响已评审。
- 用户可见变化已更新文档和本地化资源。
- 无与该任务直接相关的 P0/P1 未解决缺陷。

### 14.6 缺陷等级

| 等级 | 定义 | 发布处理 |
|---|---|---|
| P0 | 凭据/数据泄漏、RCE、普遍崩溃、无法连接核心场景 | 立即停止发布，必须修复 |
| P1 | 主要功能不可用、数据损坏、常见配置严重错误 | 正式版前必须修复 |
| P2 | 有替代路径的功能或兼容问题 | 评审后可延期 |
| P3 | 轻微视觉、文案和低影响问题 | 进入后续迭代 |

---

## 15. 发布门禁与验收

### 15.1 Alpha 门禁

- M0-M2 退出条件全部通过。
- 直接、SOCKS5、HTTP CONNECT 可完成 1 小时真实会话。
- 证书与凭据流程通过安全评审。
- 无 P0，核心路径无已知数据损坏。

### 15.2 Beta 门禁

- M3-M4 批准范围全部完成。
- 兼容矩阵完成度至少 90%，缺口有明确风险批准。
- 自动化测试稳定，连续 10 个主干构建无核心回归。
- 签名、公证和增量/完整更新链路通过。
- P0 为 0；P1 仅允许有书面批准且不涉及安全、数据或核心连接。

### 15.3 1.0 正式版门禁

- 所有 P0/P1 为 0。
- M5/M6 退出条件完成。
- macOS 11 Intel、macOS 11 Apple Silicon 及当前 macOS 验收通过。
- 支持矩阵中的 Windows、代理和 RD Gateway 场景通过。
- 8 小时长稳、500 次循环连接、睡眠/网络恢复通过。
- 外部安全评估高危/严重问题清零。
- SBOM、第三方许可证、隐私说明、用户与管理员文档齐全。
- DMG、应用、框架、更新包签名有效，公证票据已 staple。
- 发布回滚、旧版本兼容、崩溃符号和应急响应流程已演练。

---

## 16. 风险登记册

概率/影响：高、中、低。每周评审开放风险。

| ID | 风险 | 概率 | 影响 | 缓解措施 | 责任人 | 状态 |
|---|---|---:|---:|---|---|---|
| R-001 | FreeRDP 候选版本无法以 macOS 11 双架构稳定构建 | 中 | 高 | M0 首周验证；固定工具链；维护最小补丁集 | 待定 | 开放 |
| R-002 | 当前 Apple 签名/公证工具链与 11.0 deployment target 组合变化 | 中 | 高 | 分离构建机与运行目标；公证 PoC；归档工具链 | 待定 | 开放 |
| R-003 | 本地隧道导致 RDP 目标证书身份处理错误 | 中 | 高 | M0 验证自定义 transport/目标名；安全测试 | 待定 | 开放 |
| R-004 | 企业 HTTP 代理拒绝 3389 CONNECT | 高 | 中 | 路径测试、明确提示、优先 RD Gateway/443 | 待定 | 开放 |
| R-005 | 复杂键盘布局和 IME 出现输入错误 | 高 | 中 | 扫描码模型、实机布局矩阵、可配置映射 | 待定 | 开放 |
| R-006 | FreeRDP/编解码器存在内存安全漏洞 | 中 | 高 | 进程隔离评估、sanitizer、fuzz、快速升级 SLA | 待定 | 开放 |
| R-007 | 多屏/4K/视频性能不达标 | 中 | 高 | Metal、脏矩形、缓冲复用、分档性能目标 | 待定 | 开放 |
| R-008 | RD Gateway 企业认证组合超出既定范围 | 中 | 高 | M0 能力矩阵；测试域；明确支持认证方式 | 待定 | 开放 |
| R-009 | 某些设备重定向在 macOS 11 不稳定 | 高 | 中 | 单独 feature flag；默认关闭；按能力矩阵发布 | 待定 | 开放 |
| R-010 | 站外自动更新供应链风险 | 低 | 高 | 双重签名验证、密钥隔离、回滚演练 | 待定 | 开放 |
| R-011 | 缺少 Intel/macOS 11 长期测试硬件 | 中 | 高 | 项目启动即采购/保留；建立硬件轮换方案 | 待定 | 开放 |
| R-012 | 需求“完整版”持续扩张导致延期 | 高 | 高 | 使用本文范围和需求 ID；变更必须走第 18 节流程 | 产品负责人 | 开放 |

---

## 17. 架构决策记录（ADR）待办

每个 ADR 至少包含背景、方案、决策、后果、验证证据和回滚条件。

| ADR | 主题 | 最晚决策点 | 状态 |
|---|---|---|---|
| ADR-001 | FreeRDP 精确版本、构建参数和补丁策略 | M0 | 评审中 |
| ADR-002 | AppKit 主体与可选 SwiftUI 使用边界 | M1 | 已接受 |
| ADR-003 | 自定义 socket/BIO 与 loopback 隧道二选一 | M0 | 已接受 |
| ADR-004 | 目标证书信任存储和变化策略 | M1 | 评审中 |
| ADR-005 | Metal 主渲染器及 Core Graphics fallback | M0 | 评审中 |
| ADR-006 | 每会话线程还是 XPC 进程隔离 | M1 | 临时决定 |
| ADR-007 | SQLite 封装和迁移机制 | M1 | 待办 |
| ADR-008 | 自动更新框架和签名体系 | M3 | 待办 |
| ADR-009 | RD Gateway 支持的认证矩阵 | M0/M4 | 待办 |
| ADR-010 | 遥测策略：默认关闭、最小化或完全不采集 | M1 | 待办 |
| ADR-011 | 打印机/摄像头/智能卡正式版范围 | M0 | 待办 |
| ADR-012 | 配置导入导出格式与企业管理策略 | M3 | 评审中（策略已接入源码） |

---

## 18. 变更控制

任何影响正式版范围、发布日期、安全模型、数据格式或支持矩阵的变化必须：

1. 引用需求、风险或缺陷 ID。
2. 描述用户价值、实现成本、测试成本和安全影响。
3. 说明对里程碑和兼容矩阵的影响。
4. 由产品负责人、技术负责人和测试负责人批准；安全相关变化增加安全负责人。
5. 更新本文档、相关 ADR 和版本记录。

变更记录：

| 日期 | 版本 | 变化 | 原因/决策 | 作者 |
|---|---|---|---|---|
| 2026-07-27 | 0.1.0 | 建立完整产品、技术、里程碑与跟踪基线 | 项目启动 | Codex |
| 2026-07-27 | 0.2.0 | 建立工程与主要源码骨架；实现代理协议、持久化、FreeRDP 桥接、Metal、AppKit 工作流；修复多会话、重连、认证提示和目录授权问题；记录 Mac 构建阻塞 | 开始按基线实施，未达到任何里程碑退出条件 | Codex |
| 2026-07-27 | 0.2.1 | 凭据保存统一为两阶段事务；收紧会话终态；修复 Metal fallback、拖拽和键盘模式；隧道增加代次取消与连接回收；补齐多文件导入队列、SQLite 错误检查及 Windows 静态门禁 | 修复源码审查发现的数据一致性和生命周期问题；仍未达到任何里程碑退出条件 | Codex |
| 2026-07-27 | 0.2.2 | 增加临时代理凭据与取消语义、配置删除和 Keychain 回滚事务、数据库回滚失败报告及三文件隔离恢复事务、企业 MDM 策略、统一路由校验、SOCKS5 IPv4/IPv6 ATYP、协议编码前边界、编辑器整数安全、帧合并与 256 MiB 边界，以及配置/归档/`.rdp`/凭据/共享书签输入门禁；文件导入改为有界流式读取；补充 Xcode 测试门禁和管理员文档 | 继续加固安全边界和故障一致性；所有新增项仍待 macOS 构建、自动化测试运行和实机验收 | Codex |
| 2026-07-27 | 0.2.3 | 完成 Windows 全仓静态审计；增加标签搜索、配置/凭据唯一所有权、乐观并发和跨存储事务串行化；修复删除/更新、并发回滚、时间戳回退和恢复后 Keychain 残留；备份清除全部凭据引用；强化 `.rdp` 敏感键、HTTP CONNECT、文件面板兼容和逐架构 Universal 2 依赖闭包门禁；新增审计报告与测试 | 修复可由当前源码确认的问题并建立 Mac 首次构建/实机验收清单；已完成任务仍为 0 | Codex |
| 2026-07-27 | 0.2.4 | 公开 GitHub 仓库并持续修复首次 macOS CI 中的 FreeRDP 头文件、Swift 并发、framework 元数据、Universal 2 依赖解析和签名问题 | 以真实 runner 结果逐项收敛构建问题，尚未完成首次全绿 | Codex |
| 2026-07-27 | 0.2.5 | GitHub Actions `30288609403` 首次全绿；Universal 2 artifact 通过 macOS 11.7.10 Intel 双 slice、签名和 12 秒启动验证；关闭四个环境阻塞并完成 4 项任务 | 建立首个可复现的 macOS 11 Intel 构建与运行证据，继续 Apple Silicon、实网 RDP 和发布验收 | Codex |
| 2026-07-28 | 0.2.6 | 撤回“进程存活即启动成功”的错误结论；修复程序化 AppKit 入口未安装 delegate 导致的无窗口问题；增加生命周期回归测试；记录 CI `30316764662`、新 artifact 和 macOS 11 Intel 主窗口证据 | 用户真机报告应用无界面；验证发现旧产物窗口数为 0，新产物已创建主窗口，待解锁态 onscreen 复验 | Codex |
| 2026-07-28 | 0.2.7 | 修复本地化端口被截断、代理握手错误被吞和会话空白页；增加严格端口、代理准备失败、中央状态/重试和首帧显示保护；修复真机 profile 并验证真实 SOCKS5/HTTP CONNECT 路径 | 用户报告连接窗口空白且代理测试始终失败；取证确认 `3389/7897` 被保存为 `3/7`，并完成 CI #29 与真机网络验证 | Codex |
| 2026-07-28 | 0.2.8 | 修复 FreeRDP 静态通道 provider 未注册导致的 `0x00020001`；设置页改为稳定 tab 容器并固定测试按钮 alignment width；增加错误摘要、错误码分类及布局回归测试；CI `30325083089` 全绿 | 用户报告 Direct 连接持续在 PreConnect 失败，且每次测试连接后设置页内容累计偏移；源码与 FreeRDP 固定版本取证确认两个根因 | Codex |
| 2026-07-28 | 0.2.9 | 增加 FreeRDP 原生错误诊断；定位 `0x0002000D` 为 OpenSSL 3 legacy provider 缺失导致的 NTLM MD4 初始化失败；改用 WinPR 内置 MD4/RC4 并增加无外部 provider 的逐架构加密向量门禁 | 真机已完成 TCP、X.224、TLS 取证，失败点收敛到 NLA/NTLM；避免应用运行时依赖 Homebrew OpenSSL 模块目录 | Codex |
| 2026-07-28 | 0.3.0 | 完成 Direct TLS/NLA 与首帧验收；修复代理 loopback 地址污染 NLA/SPN 服务器身份、分辨率本地化解析与持久化、Keychain 查询阻塞主线程；增加服务器地址映射、配置复制、分辨率边界和后台线程测试 | 用户确认 Direct 已连接，但完整代理 RDP 仍失败且分辨率无法保存；FreeRDP 3.30.0 源码和真机数据库取证确认根因 | Codex |
| 2026-07-28 | 0.3.1 | 修复 loopback listener 在 accepted socket 进入 `.ready` 前被取消的竞态；增加真实 TCP 双向 relay、预读数据、单连接和停止后重启集成测试；完成分辨率真机持久化验收 | SOCKS5 已完成代理握手，但完整 RDP 在本地随机端口接入阶段失败；原生日志和源码确认 listener 生命周期早于 downstream TCP 握手结束 | Codex |
| 2026-07-29 | 0.3.2 | 修复 macOS 11 会话图标为空；全屏工具栏改为顶部中央自动收起的小刘海；显式启用 FreeRDP Display Control；增加远端帧尺寸确认、有限重试、诊断和 AppKit 回归测试 | 用户确认代理可连接后反馈全屏顶部仍占空间、图标不可见，且跟随窗口未体现 Windows 端分辨率变化；macOS 11 与 FreeRDP 3.30.0 源码取证确认兼容和可观测性缺口 | Codex |
| 2026-07-29 | 0.3.3 | 初始化并幂等释放 FreeRDP RDPGFX GDI 图形管线；订阅 `GraphicsReset`，与经典 `DesktopResize` 统一发布服务器实际尺寸；增加 Display Control/RDPGFX 持久化诊断 | 用户复验确认窗口和全屏均不改变远端分辨率；真机 profile 排除设置问题，FreeRDP 3.30.0 源码确认已启用 RDPGFX 却未安装 GDI 回调的协议缺口 | Codex |
| 2026-07-29 | 0.3.4 | 显式登记 `disp`/`rdpgfx` 动态通道并记录加载状态；为未建立 RDPEDISP 的服务器增加带激活宽限、防抖和限频的最新画布尺寸重连降级 | 截图确认远端 framebuffer 固定为 `1180x712`，统一日志确认所有请求因 Display Control 未激活而在本地拒绝；初始连接尺寸正确，界定为在线调整能力缺失 | Codex |
| 2026-07-29 | 0.3.5 | 将连接路径测试从 TCP/SOCKS/CONNECT 握手升级为最小 RDP X.224 协商验证，并增加代理提前关闭的明确诊断与协议解析测试 | Direct 返回合法协商响应，而同一目标经 Clash 当前新加坡节点在 SOCKS5 成功后立即 EOF；应用外探针和 mihomo debug 日志确认是当前代理出站不支持该 RDP 路径 | Codex |

---

## 19. 项目启动前必须确认的问题

这些问题不阻止阅读或评审文档，但必须在 M0 启动评审中确定责任人和截止日期：

- [ ] 产品名称、Bundle Identifier、版权主体和开源发布策略。
- [ ] “完整版”中打印机、摄像头、智能卡、Kerberos 的商业优先级。
- [ ] 首发是否必须包含 RD Gateway；支持哪些认证方式。
- [ ] 是否允许匿名产品遥测；默认值、采集字段和数据存放地区。
- [ ] 是否需要企业集中配置、MDM、配置锁定和审计导出。
- [ ] 是否需要 FIPS 或特定密码合规标准。
- [ ] 目标发布国家/地区、隐私法规和出口合规要求。
- [ ] 许可模式：免费、买断、订阅或企业授权；是否需要账户服务。
- [ ] Apple Developer 账号、签名权限、更新域名和安全报告邮箱。
- [ ] 项目团队、负责人、预算、测试硬件和 Windows/RD Gateway 实验室。

---

## 20. 下一步行动

项目批准后按顺序执行：

1. 任命产品、技术、测试和安全负责人，完成第 19 节责任分配。
2. 召开 M0 启动评审，冻结 PoC 验收条件和三周时间盒。
3. 建立第 9 节仓库骨架和双架构 CI。
4. 完成 M0-01 至 M0-12，以实测结果更新依赖、能力矩阵、风险和总工期。
5. M0 退出评审批准后进入 M1；未通过的核心能力先做技术决策，不直接扩展 UI。

本文档的第一项实际进度更新应是：填写项目负责人、M0 起止日期、FreeRDP 候选版本和 macOS 11 测试设备清单。
