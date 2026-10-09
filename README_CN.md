# xntfs — macOS 上的 NTFS(FSKit + ntfs-3g)

> 📖 English version: [English](README.md)

<a href="https://apps.apple.com/cn/app/xntfs/id6782636021"><img src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/zh-cn?size=250x83" alt="在 App Store 下载 xntfs" height="44"></a>

一个 macOS 应用 + **FSKit 文件系统扩展**,使用 [ntfs-3g](https://github.com/tuxera/ntfs-3g)
引擎读写 NTFS 卷。无需内核扩展,无需 macFUSE。

`ntfs3g` 应用扩展复用了可移植的 **`libntfs-3g`** 核心(所有 NTFS 逻辑——MFT、运行列表、
压缩、安全描述符、`$LogFile`),在其上套了一层很薄的 FSKit `FSVolume` 映射层,做法与
ntfs-3g 自带的 `src/ntfs-3g.c` 把 FUSE 映射到 libntfs 如出一辙。

启用扩展后，macOS 可以在无需后台应用的情况下将支持的 NTFS 磁盘挂载到 `/Volumes`。
`xntfs` 应用列出磁盘和映像、显示实际挂载及只读状态，并协助诊断扩展设置。
手动挂载方式随 macOS 版本不同，见下文。

```
xntfs.app  (SwiftUI,App 沙盒 —— 控制面板;不是后台代理)
 ├─ AppModel ── DiskArbitrationMonitor   检测/列出 NTFS 磁盘(仅检测)
 │           └─ MountService             手动挂载/卸载(DiskArbitration)、映像附加
 └─ Contents/Extensions/ntfs3g.appex     FSKit 模块 —— 真正的 NTFS 驱动(+ 自动挂载)
        ntfs3g.swift            @main UnaryFileSystemExtension
        ntfs3gFileSystem.swift  probe / load / unload / fsck
        ntfs3gVolume.swift      每个 FSVolume 操作 → nfsk_* 桥接
        bridge/ntfs_fskit.c     libntfs 逻辑(mount、getattr、readdir、read、write、create…)
        bridge/ntfs_device_fskit.m  基于 FSBlockDeviceResource 的块 I/O(按扇区对齐的 RMW)
        + libntfs-3g.a(arm64 + x86_64,静态链接)
```

## 状态

| 部件 | 状态 |
|-------|-------|
| `ntfs3g` 扩展(NTFS 读写引擎) | ✅ 可编译;引擎静态链接;[已实现操作与边界](docs/fskit-feature-alignment.md) |
| `xntfs` 应用(UI、监视器、挂载服务、设置) | ✅ 可编译 |
| 英文 + 简体中文本地化 | ✅ `Localizable.xcstrings`(en、zh-Hans) |
| 应用图标 | ✅ 已生成,完整 AppIcon 集 |
| 在 Mac 上端到端挂载 | 已在 macOS 15.8 和 27.0 验证；扩展仍需 FSKit 签名授权并由用户开启 |

扩展使用受限的 FSKit 权限。本地构建需要签名团队的描述文件授权该权限；编译成功不代表扩展已启用。

当前引擎固定为 [ntfs-3g 2026.9.28](https://github.com/tuxera/ntfs-3g/releases/tag/2026.9.28)，
修复了 2026.9.18 中新建文件和目录可能返回 `EINVAL` 的回归问题。详见 [issue #7 验证记录](docs/issue-7-validation.md)。

## 已知缺陷

- **macOS 15 文件生命周期：原生修复已在 macOS 15.8 验证。**
  当前源码会保留已删除或被覆盖的打开文件，直到最后关闭，不依赖 macOS 26 的 API。
  在 macOS 15.8 x86_64 上，桥接层、直接 Swift 测试及 TestFlight 1.0.9 (13) 的实际挂载生命周期测试均已通过。
  旧构建仍可能使已有句柄失效，删除或覆盖前请先关闭文件。macOS 26+ 继续使用
  FSKit 的模拟机制，已在 macOS 27 验证；删除后仍打开的文件，其链接数仍显示为 1。
  见 [issue #4](https://github.com/HuanchuanTech/xntfs/issues/4)
  和[本轮验证记录](docs/fskit-feature-alignment.md)。
- **macOS 15 上，文件打开期间的已分配空间信息可能不及时更新。**
  实际挂载测试中，普通写入和预分配后均出现旧值，直到最后一个文件描述符关闭才更新。
  本轮测试的数据内容与逻辑文件大小均保持正确。同一测试在 macOS 27 通过，但原因尚未确定。
  见[专项复测记录](docs/fskit-feature-alignment.md#focused-allocation-retest)。

## 文件系统操作

当前源码支持修改原生创建时间与隐藏标志、符号链接、卷改名、普通文件的持久空间预分配，
以及 macOS 27 上的稀疏区域查询。挂载前会进行只读的安全性预检，不提供完整检查或修复。
这些是源码能力，不代表所有已发布版本均已包含。详见[设计、测试与能力边界](docs/fskit-feature-alignment.md)。

## Finder 元数据

当前源码将扩展属性（包括 Finder 标签和资源叉）保存到同名的 NTFS 备用数据流（ADS），
不再为新属性生成 AppleDouble `._` 文件。单个属性上限为 **128 KiB**，与 macOS 27
实际挂载测试中观察到的 FSKit 限制一致。这个限制不影响普通文件内容的大小。

**已有 `._` 文件不会自动迁移或删除。** 迁移前，其中的元数据不会通过原生扩展属性接口显示。
升级或迁移前，请同时备份原文件及其 `._` 伴随文件。使用新驱动以读写方式挂载后，可以用
macOS 自带的 `dot_clean` 将旧元数据合并到原生属性中。例如，仅处理一个目录、不递归子目录：

```sh
dot_clean -f -v "/Volumes/YourDrive/YourFolder"
```

此命令会修改元数据，并删除合并成功的 `._` 文件。完成后请检查标签和资源叉，并保留备份。
不要直接批量删除 `._`，也不要使用跳过合并、直接丢弃文件的清理选项。应用不会自动执行此命令。

## 六大功能

1. **本地化(英文 + 简体中文)** —— `xntfs/Localizable.xcstrings`(String Catalog)。
   新增语言只需添加 `localizations` 条目。
2. **可移动 NTFS 自动挂载** —— 由**系统**而非应用处理:扩展的 `Info.plist` 注册了 NTFS
   `FSMediaTypes`(`Windows_NTFS`、MS Basic-Data GUID、无分区表),于是 DiskArbitration
   可在无需应用进程的情况下把支持的 NTFS 磁盘挂载到 `/Volumes`。macOS 15 上内置 NTFS
   驱动可能优先被选中，此时需要手动兼容方案。
3. **挂载位置** —— 磁盘挂载到 `/Volumes/<名称>`,路径由系统选择并对重名去重。沙盒化的 FSKit
   卷**无法挂载到自定义文件夹**(扩展只能访问 `/Volumes` 及其自身沙盒临时路径),所以
   `/Volumes` 是唯一目标。
4. **同时挂载多个磁盘** —— 设备按 BSD 名跟踪,各自独立挂载。
5. **手动挂载/卸载** —— macOS 27 上可在应用内选择只读或读写挂载；macOS 15 上提供
   可复制的终端命令，为所选卷（包括磁盘工具已附加的映像）使用 xntfs 挂载；macOS 26
   上使用磁盘工具。已挂载卷可在 Finder 中显示或从应用推出。
6. **磁盘映像** —— macOS 27 上可在应用内选择并挂载单卷原始 NTFS 映像；有分区表或压缩
   映像需用磁盘工具打开。较早系统通过磁盘工具附加映像，macOS 15 上可对所选分区使用
   手动兼容方案。

## 构建

这是个普通的 Xcode 工程——打开 `xntfs.xcodeproj`,构建 `xntfs` scheme。扩展的构建设置
(桥接头、`libntfs-3g.a` 链接、头搜索路径、`HAVE_CONFIG_H`)与应用的构建设置
(权限、zh-Hans 区域)都已提交;它们由 `scripts/wire_project.rb` 应用(可重复运行、幂等,
需要 `xcodeproj` gem)。

在 Xcode 中构建前,先生成通用静态库和共享的 `config.h`(需要 Autotools 和 GNU libtool):
```sh
./scripts/build-libntfs.sh
lipo -archs build/libntfs-universal/libntfs-3g.a
```
脚本分别构建 arm64 和 x86_64,再合并到 `build/libntfs-universal/`。该目录不提交到 Git;
全新检出或更新 ntfs-3g 子模块后需要重新运行脚本。

工程默认使用维护者的签名团队。本地运行前请在 Xcode 中选择自己的团队并配置 FSKit 能力。

## 配置签名(实际运行扩展所必需)

扩展声明了**受限**权限 `com.apple.developer.fskit.fsmodule`(`ntfs3g/ntfs3g.entitlements`)。
macOS(AMFI)只有在该权限被描述文件授权后才会加载扩展。在**自动签名**、团队 `529LJDH392`
下,只有当该团队的 App ID 在 Apple 开发者门户里开通了 **FSKit File System Module** 能力时
才行。自行构建时要先替换工程的签名团队。开通后,在 **系统设置 → 通用 → 登录项与扩展 → 文件系统扩展** 中启用该模块。

## 沙盒与挂载

各系统的挂载路径不同：

- **macOS 27：**应用通过 FSKit 和 Disk Arbitration API 在应用内挂载卷与映像。
- **macOS 26：**启用扩展后可自动挂载；手动挂载和附加映像通过磁盘工具完成。
- **macOS 15：**内置 NTFS 驱动可能在自动挂载时优先选中。应用提供针对单个卷的可复制
  终端命令，临时选择 xntfs。命令由用户确认并输入管理员密码，结束后删除临时 `.fs` 项；
  应用本身不会执行它。见[兼容方案说明](docs/macos15-compatibility.md)。

> 这是*技术*能力结论;App Review 是另一道独立的政策关卡。

## 目录结构

```
xntfs/                     应用 target(SwiftUI)
  xntfsApp.swift           @main App + Settings 场景
  ContentView.swift        设备/映像列表 + 按系统版本提供挂载操作
  DiskUtility.swift        打开 Apple 磁盘工具(挂载 / 附加映像)
  MountSheet.swift         macOS 27 应用内挂载 sheet
  LegacyMountSheet.swift   macOS 15 手动挂载说明
  CopyableCommand.swift    可复制命令控件
  DiagnosticsView.swift    扩展状态诊断页
  SettingsView.swift       默认只读偏好
  Model/NTFSDevice.swift
  Services/                AppModel、AppSettings、DiskArbitrationMonitor、MountService、
                           ExtensionStatus
  Localizable.xcstrings    en + zh-Hans
  Assets.xcassets/AppIcon  生成的图标集
ntfs3g/                    FSKit 扩展 target
  ntfs3g*.swift            @main + FSUnaryFileSystem + FSVolume + FSItem
  bridge/                  ntfs_fskit.{h,c}、ntfs_device_fskit.m、桥接头
  Info.plist               FSShortName=xntfs、FSMediaTypes、块资源
  ntfs3g.entitlements      com.apple.developer.fskit.fsmodule + 沙盒
ntfs-3g/                   上游源码 + 构建出的 libntfs-3g.a
scripts/wire_project.rb    应用扩展/应用的构建设置(xcodeproj gem)
assets/xntfs-icon.svg      图标源文件
```
