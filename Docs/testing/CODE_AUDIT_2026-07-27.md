# 代码审计报告（2026-07-27）

## 1. 结论

本轮已完成当前 Windows 工作区可执行的全量静态代码审计，并修复可由现有源码确定的安全、数据一致性、并发、网络协议、文件输入和发布门禁问题。仓库静态校验已通过，95 个自动化测试用例已写入源码。

这不代表产品开发完成，也不代表测试已经通过。当前主机没有 Swift、Xcode、XcodeGen、Clang 或 CMake，无法编译 Swift/Objective-C++、运行 XCTest、构建 FreeRDP、验证 Universal 2、签名/公证或执行 macOS 11 与 Windows 实机验收。因此所有开发计划任务仍为开发中、待办或阻塞。

## 2. 审计基线

- 基准文档：`DEVELOPMENT_PLAN.md` 0.2.3。
- 审计范围：`Sources`、`Tests`、`Tools`、`Config`、`Vendor/manifest.json`、`project.yml`、`Package.swift`、GitHub Actions、ADR、管理员和安全文档。
- 源码规模：32 个 Swift/Objective-C++/头文件，约 6,515 行。
- 测试规模：9 个测试文件，95 个测试用例，约 1,579 行。
- 方法：逐模块代码复核、跨模块数据流复核、敏感信息入口检索、无界输入/强制转换检索、并发与取消路径复核、构建和供应链脚本复核、仓库静态门禁。
- 限制：仓库文件当前均为 Git 未跟踪文件，`git diff --check` 不覆盖这些源码，不能作为全量证据。

## 3. 已修复问题

### 3.1 安全与凭据

- 三类凭据使用独立 Keychain 引用，并拒绝不同配置共享同一引用。
- 配置写入采用 Keychain、SQLite 和旧引用清理的补偿事务；回滚清理失败进入诊断。
- 凭据事务与配置删除/恢复清理在进程内串行化，避免失败事务回滚覆盖另一会话已经提交的凭据。
- 配置删除、替换和备份恢复只删除数据库确认已无其他配置引用的 Keychain 项。
- 备份导出与恢复导入均清除目标、代理和网关 Keychain 引用，防止篡改备份后关联本机既有凭据。
- 恢复覆盖配置后返回新产生的无引用凭据集合，由应用清理；失败记录诊断，不破坏已提交的恢复。
- 会话凭据保存要求配置仍然存在；删除后的后台保存不会以相同 UUID 复活配置。
- 目标、代理、网关临时凭据在取消或准备失败时统一清除。
- 诊断字段名在去分隔符归一化后拒绝密码、授权、令牌、凭据、Keychain、剪贴板、帧和文件内容等敏感类别。

### 3.2 数据与并发

- SQLite 配置写入具有单配置 8 MiB、总负载 256 MiB、归档 64 MiB 和 10,000 条上限。
- 保存采用 `updatedAt` 乐观并发检查；完整编辑检测基线差异，凭据保存只合并对应凭据字段。
- 存在性、版本检查和写入位于同一 `BEGIN IMMEDIATE` 事务，消除检查与提交之间的竞态窗口。
- 配置删除、保留引用计算与删除位于同一 SQLite 事务。
- 备份批量导入的容量、所有权检查和写入位于同一事务，失败完整回滚。
- `lastConnectedAt` 和 `updatedAt` 保持单调，不再由延迟到达的旧连接时间回退。
- 搜索覆盖名称、主机和标签，并按大小写/变音符号不敏感方式匹配；通配符按字面量处理。
- 企业策略只持久化用户当前允许修改的字段，策略临时限制不会永久覆盖原配置。

### 3.3 文件与协议输入

- `.rdp`、配置归档和其他导入使用有界分块读取，不使用无界 `Data(contentsOf:)` 或 `String(contentsOf:)`。
- `.rdp` 限制为 1 MiB、单行 16 KiB、最多 4,096 个设置。
- `.rdp` 二进制字段全部拒绝；敏感键在移除 Unicode 分隔符后识别，阻止 `pass-word`、`access_token` 等变形绕过。
- 仅放行明确安全的凭据提示元数据，如 `prompt for credentials`。
- SOCKS5 支持域名、IPv4、IPv6 ATYP，并在编码前校验目标与 UTF-8 凭据长度。
- HTTP CONNECT 对请求、响应头、Basic 凭据、状态行和 RFC token 头名实施边界和控制字符校验。
- 当前未实现的“本机解析目标 DNS 后交给代理”模式被明确拒绝，避免静默改变隐私和路由语义。
- AppKit 文件面板已迁移到 macOS 11 的 `UniformTypeIdentifiers`，清除警告即错误构建中的弃用 API。

### 3.4 会话、渲染与资源生命周期

- 每个会话具有独立 ID，旧会话回调不会污染新会话。
- loopback 隧道只绑定 `127.0.0.1` 随机端口，只接受一次下游连接，并按代次取消监听、连接和转发任务。
- 网络切换、睡眠、手动断开和重连路径清理隧道、按键和临时凭据。
- 桥接层帧缓冲校验宽度、高度、步幅、整数溢出和 256 MiB 上限，只保留等待主线程呈现的最新帧。
- Metal 不可用时自动使用 Core Graphics；两条渲染路径共享相同帧边界校验。
- FreeRDP 连接配置要求 TLS/NLA，并明确禁用旧 RDP Security。

### 3.5 构建与供应链

- FreeRDP 固定到 3.30.0、commit 和 tag object；构建脚本从单一 manifest 读取固定信息。
- GitHub Actions 第三方 action 固定为完整 commit SHA。
- Universal 2 门禁遍历 `.app/Contents` 中全部 Mach-O 文件。
- 每个 Mach-O 分别验证 arm64/x86_64、代码签名和两个架构的 macOS 11.0 最低版本。
- 使用 `otool -L` 与实际 `LC_RPATH` 验证运行时依赖闭包，拒绝 Homebrew、本机 `/usr/local`、`Vendor/build` 和其他非系统绝对路径泄漏。
- Gatekeeper、签名、公证和 staple 失败不会被静默忽略。

## 4. 当前静态验证证据

以下命令已在 Windows 当前工作区执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Tools\validate-repository.ps1
```

结果：通过 UTF-8/格式、有界 I/O、JSON/plist、依赖固定、本地化键与占位符、CI action 固定、部署目标和发布脚本结构检查。

以下风险检索结果为零：

```text
allowedFileTypes
Data(contentsOf:) / String(contentsOf:)（Sources）
try! / as!
异步表达式直接位于 XCTest 自动闭包
```

保留的特殊用法只有 SQLite `SQLITE_TRANSIENT` 所需的 `unsafeBitCast`，以及纯代码 AppKit 视图/控制器的 `fatalError(init(coder:))`。两者均非本轮发现的未受控输入或强制类型转换。

## 5. 当前无法验证的项目

- Swift 5.7/SwiftPM 编译和 95 个 XCTest 实际运行。
- XcodeGen 工程生成、AppKit/Metal target 和 Objective-C++ Bridge 编译。
- FreeRDP 3.30.0 回调签名、setting ID、GDI resize、通道加载和插件打包的真实头文件匹配。
- arm64/x86_64 构建、Universal 2 依赖闭包脚本实际运行。
- Developer ID 签名、Hardened Runtime、公证、staple 和 Gatekeeper。
- macOS 11 Intel 与 Apple Silicon 启动、UI、Retina、全屏、输入法和性能。
- Windows TLS/NLA、证书变化、错误码、断线恢复、RD Gateway 和企业代理。
- 剪贴板、动态分辨率、音频、麦克风、rdpdr、文件夹、打印机、摄像头、智能卡和多显示器。
- Bash 语法检查；Windows Bash/WSL 返回 `Bash/Service/CreateInstance/E_ACCESSDENIED`。

## 6. 首次 Mac 构建检查单

1. 在包含 macOS 11 SDK 兼容部署目标的 Xcode 环境安装固定版本 XcodeGen、CMake、Ninja 和 pkg-config。
2. 核对 `Vendor/manifest.json` 的 FreeRDP tag object 与 commit，完成许可证和 CVE 复核。
3. 执行 `Tools/build-freerdp.sh`，确认两个架构使用相同配置并锁定 OpenSSL 来源。
4. 执行 `Tools/bootstrap-macos.sh`，检查 XcodeGen 无警告生成工程。
5. 执行 `swift test --parallel` 和 Xcode `RemoteDesktopTests`；保存 `.xcresult`。
6. 重点编译复核 `RDPSession.mm` 的证书、LogonErrorInfo、settings、GDI 和通道 API。
7. 运行 ASan、UBSan 和 TSan 的核心连接、取消、关闭、配置与 Keychain 故障路径。
8. 分别在 x86_64 与 arm64 构建，再执行 `Tools/verify-universal.sh`。
9. 在 macOS 11 Intel、macOS 11 Apple Silicon 和当前 macOS 运行启动、文件面板、Keychain、SQLite、渲染和输入冒烟测试。
10. 归档后执行签名、公证、staple、Gatekeeper、新装和覆盖升级验证。

## 7. Windows、网关和代理实机矩阵

| 领域 | 最低矩阵 | 关键异常 |
|---|---|---|
| Windows | Windows 10/11 Pro/Enterprise；Server 2016/2019/2022/2025 | NLA 失败、账户锁定、证书未知/变化、授权拒绝、服务重启 |
| Direct | IPv4、IPv6、DNS、自定义端口、VPN | DNS 失败、超时、RST、网络切换、睡眠唤醒 |
| SOCKS5 | 无认证、用户名/密码；域名、IPv4、IPv6 | 方法拒绝、认证失败、CONNECT 拒绝、截断/异常响应 |
| HTTP CONNECT | 无认证、Basic、HTTP/HTTPS、Squid 和企业代理 | 403、407、非 2xx、超大/畸形头、代理证书变化、禁止 3389 |
| RD Gateway | 至少两个受支持 Windows Server 版本 | 网关/目标独立凭据、证书变化、HTTP/RPC transport、CAP/RAP 拒绝 |
| 稳定性 | 8/24 小时、500 次连接/断开、Wi-Fi 切换 | 内存、句柄、线程、端口、Keychain 和隧道泄漏 |
| 显示输入 | Retina/非 Retina、1080p/1440p/4K、常用中英和欧洲布局 | 坐标、组合键、修饰键释放、IME、多空间和全屏 |

测试账号、密码、证书私钥和代理认证材料不得进入仓库、日志、截图或测试结果附件。

## 8. 发布阻塞项

- 没有可用的 macOS/Xcode 构建和测试环境。
- 无法下载/核对锁定的 FreeRDP 上游源码，OpenSSL Universal 2 来源未固定。
- 缺少 macOS 11 Intel/Apple Silicon 硬件和 Windows/RD Gateway/企业代理实验室。
- 最终 Bundle Identifier、Keychain service prefix、代码签名团队和产品标识尚未确定，当前仍为 `com.example.RemoteDesktop`。
- FreeRDP 通道能力尚未通过真实头文件、构建和实机验证。
- 自动更新、SBOM、CVE、sanitizer、fuzz、长稳、渗透测试和隐私评审未完成。

## 9. 最终判断

当前状态是“Windows 环境下的完整静态审计、可确认问题修复、测试源码补充和发布门禁增强已完成”。它不是“产品全部开发完成”，也不是可发布候选版本。只有完成开发计划 M0-M6 的构建、自动化、实机、安全、签名和发布证据后，才可将相应任务标为已完成。
