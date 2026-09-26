# xntfs — macOS 上的 NTFS(FSKit + ntfs-3g)

> 📖 English version: [English](README.md)

一个 macOS 应用 + **FSKit 文件系统扩展**,使用 [ntfs-3g](https://github.com/tuxera/ntfs-3g)
引擎读写 NTFS 卷。无需内核扩展,无需 macFUSE。

`ntfs3g` 应用扩展复用了可移植的 **`libntfs-3g`** 核心(所有 NTFS 逻辑——MFT、运行列表、
压缩、安全描述符、`$LogFile`),在其上套了一层很薄的 FSKit `FSVolume` 映射层,做法与
ntfs-3g 自带的 `src/ntfs-3g.c` 把 FUSE 映射到 libntfs 如出一辙。

NTFS 磁盘**由系统自动挂载到 `/Volumes`**(DiskArbitration 探测扩展注册的 `FSMediaTypes`
——无需任何应用进程,与内置的 exFAT/MSDOS 模块完全一样)。`xntfs` 应用是一个**控制面板**:
列出 NTFS 磁盘与已附加的磁盘映像,推出/在 Finder 中显示已挂载卷,并有一个扩展状态诊断页。
沙盒应用无法自行挂载第三方 FSKit 卷或附加映像,这些操作会打开**磁盘工具**完成;日常磁盘
则由系统自动挂载。

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
| `ntfs3g` 扩展(NTFS 读写引擎) | ✅ 可编译;引擎静态链接;FSKit 协议实现完整 |
| `xntfs` 应用(UI、监视器、挂载服务、设置) | ✅ 可编译 |
| 英文 + 简体中文本地化 | ✅ `Localizable.xcstrings`(en、zh-Hans) |
| 应用图标 | ✅ 已生成,完整 AppIcon 集 |
| 在 Mac 上端到端挂载 | ⛔ 需要为你的团队开通 FSKit 权限 —— 见下文 |

NTFS 引擎本身已独立验证正确(挂载 / 枚举 / 读 / 写 / 创建,并与上游 `ntfsls`/`ntfsfix`
交叉核对);只有系统*加载*扩展这一步,依赖与你的 Apple 开发者账号绑定的代码签名/描述文件。

## 六大功能

1. **本地化(英文 + 简体中文)** —— `xntfs/Localizable.xcstrings`(String Catalog)。
   新增语言只需添加 `localizations` 条目。
2. **可移动 NTFS 自动挂载** —— 由**系统**而非应用处理:扩展的 `Info.plist` 注册了 NTFS
   `FSMediaTypes`(`Windows_NTFS`、MS Basic-Data GUID、无分区表),于是 DiskArbitration
   会用我们的模块把 NTFS 磁盘以读写方式自动挂载到 `/Volumes`——全程无需应用进程(与内置
   exFAT/MSDOS 模块同一模型)。`FSProbeOrder` 决定相对于老式只读 NTFS 驱动的优先级。
   应用只负责为 UI *检测/列出*磁盘。
3. **挂载位置** —— 磁盘挂载到 `/Volumes/<名称>`,路径由系统选择并对重名去重。沙盒化的 FSKit
   卷**无法挂载到自定义文件夹**(扩展只能访问 `/Volumes` 及其自身沙盒临时路径),所以
   `/Volumes` 是唯一目标。
4. **同时挂载多个磁盘** —— 设备按 BSD 名跟踪,各自独立挂载。
5. **手动挂载/卸载** —— 每个设备有 *Eject* 和 *在 Finder 中显示*。沙盒应用无法自行挂载第三方
   FSKit 卷,所以要(重新)挂载未挂载的 NTFS 卷时,应用提供一个 *打开磁盘工具* 按钮——在那里
   挂载(磁盘工具经由 `diskarbitrationd` 挂载,和系统自动挂载同一条路)。
6. **磁盘映像** —— 在**磁盘工具**里附加原始 NTFS 映像(*文件 ▸ 打开磁盘映像…*,或双击它);
   xntfs 随后会把该设备上的 NTFS 卷像普通磁盘一样**自动挂载**,并列在 *磁盘映像* 分节下。
   应用只是跳转到磁盘工具,而不自行运行 `hdiutil`(沙盒拦截 `Process`)。

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

## 配置签名(实际运行扩展所必需)

扩展声明了**受限**权限 `com.apple.developer.fskit.fsmodule`(`ntfs3g/ntfs3g.entitlements`)。
macOS(AMFI)只有在该权限被描述文件授权后才会加载扩展。在**自动签名**、团队 `529LJDH392`
下,只有当该团队的 App ID 在 Apple 开发者门户里开通了 **FSKit File System Module** 能力时
才行。开通后,在 **系统设置 → 通用 → 登录项与扩展 → 文件系统扩展** 中启用该模块。

## 沙盒与挂载

在 macOS 26.5 的沙盒构建上验证过:

- **自动挂载是主路径。** 系统通过扩展的 `FSMediaTypes` 把 NTFS 磁盘以读写方式自动挂载到
  `/Volumes`——无需应用进程、无需额外权限。完全可用。
- **沙盒应用无法自行挂载第三方 FSKit 卷。** DiskArbitration 挂载会被拒
  (`kDAReturnNotPrivileged`),`mount -F -t xntfs …` 也会在 FSKit 探测处被拒
  (“Permission denied”)。所以手动(重新)挂载和附加磁盘映像都交给**磁盘工具**完成,它经由
  `diskarbitrationd` 挂载——和自动挂载同一条路。
- **应用从不 shell 出去。** 沙盒拦截 `Process`(`hdiutil`、`mount` 等);应用的职责是检测、
  列出,以及一键跳转到磁盘工具。

> 这是*技术*能力结论;App Review 是另一道独立的政策关卡。

## 目录结构

```
xntfs/                     应用 target(SwiftUI)
  xntfsApp.swift           @main App + Settings 场景
  ContentView.swift        设备/映像列表 + 详情;挂载/附加走磁盘工具
  DiskUtility.swift        打开 Apple 磁盘工具(挂载 / 附加映像)
  MountSheet.swift         应用内挂载 sheet(当前禁用)
  CopyableCommand.swift    可复制命令控件(供诊断页使用)
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
