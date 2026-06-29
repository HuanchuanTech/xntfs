# xntfs — macOS 上的 NTFS(FSKit + ntfs-3g)

> 📖 English version: [English](README.md)

<a href="https://apps.apple.com/app/xntfs/id6782636021"><img src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/zh-cn?size=250x83" alt="在 App Store 下载 xntfs" height="44"></a>

一个 macOS 应用 + **FSKit 文件系统扩展**,使用 [ntfs-3g](https://github.com/tuxera/ntfs-3g)
引擎读写 NTFS 卷。无需内核扩展,无需 macFUSE。

`ntfs3g` 应用扩展复用了可移植的 **`libntfs-3g`** 核心(所有 NTFS 逻辑——MFT、运行列表、
压缩、安全描述符、`$LogFile`),在其上套了一层很薄的 FSKit `FSVolume` 映射层,做法与
ntfs-3g 自带的 `src/ntfs-3g.c` 把 FUSE 映射到 libntfs 如出一辙。

NTFS 磁盘**由系统自动挂载到 `/Volumes`**(DiskArbitration 探测扩展注册的 `FSMediaTypes`
——无需任何应用进程,与内置的 exFAT/MSDOS 模块完全一样)。`xntfs` 应用是一个**控制面板**:
列出 NTFS 磁盘与已附加的映像,提供手动挂载/卸载(到 `/Volumes`)、只读重新挂载、附加/分离
磁盘映像,以及一个扩展状态诊断页。沙盒无法运行 `hdiutil`/`mount`,因此这些在应用无法直接
执行时会以**可复制的终端命令**形式给出。

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
        + libntfs-3g.a(arm64,静态链接)
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
   卷**无法挂载到自定义文件夹**(扩展只能访问 `/Volumes` 及其自身沙盒临时路径——见*沙盒与
   挂载*),所以 `/Volumes` 是唯一目标。
4. **同时挂载多个磁盘** —— 设备按 BSD 名跟踪,各自独立挂载。
5. **手动挂载/卸载** —— 每个设备有 *Mount…*(挂到 `/Volumes`,带只读开关)和 *Eject*。
   macOS 27 上应用通过 `FSClient` 在应用内挂载;macOS 26 上沙盒应用无权挂载第三方 FSKit 卷,
   于是改为给出可复制的 `diskutil mount [readOnly] /dev/diskXsY` 命令。
6. **磁盘映像** —— *Add Disk Image…* 选择一个原始 NTFS 映像(`.img`/`.dd`/…),并给出可复制的
   `hdiutil attach [-readonly] <映像>` 命令(默认只读);附加后,该设备上的 NTFS 卷会像普通
   磁盘一样**自动挂载**。*Detach Image…* 给出 `hdiutil detach`。应用自身无法运行 `hdiutil`
   (沙盒拦截 `Process`),所以用可复制命令。

## 构建

这是个普通的 Xcode 工程——打开 `xntfs.xcodeproj`,构建 `xntfs` scheme。扩展的构建设置
(桥接头、`libntfs-3g.a` 链接、头搜索路径、`HAVE_CONFIG_H`、arm64)与应用的构建设置
(权限、zh-Hans 区域)都已提交;它们由 `scripts/wire_project.rb` 应用(可重复运行、幂等,
需要 `xcodeproj` gem)。

`libntfs-3g.a` 已预构建于 `ntfs-3g/libntfs-3g/.libs/`。要重新构建(arm64):
```sh
cd ntfs-3g
glibtoolize --force --copy --install
LIBTOOLIZE=glibtoolize autoreconf -fi -I m4
./configure --disable-shared --enable-static --disable-ntfs-3g --disable-ntfsprogs \
            --disable-crypto --disable-nls \
            CC=clang CFLAGS="-arch arm64 -isysroot $(xcrun --show-sdk-path) -mmacosx-version-min=13.0 -O2"
make -C libntfs-3g
```
> 目前**仅 arm64**(`libntfs-3g.a` 就是按这个架构构建的;`ntfs3g` target 也固定为
> `arm64`)。要支持 Intel/通用二进制,需另外为 `x86_64` 构建 libntfs-3g 并用 `lipo`
> 合并,再去掉 `ARCHS=arm64` 的固定。

## 配置签名(实际运行扩展所必需)

扩展声明了**受限**权限 `com.apple.developer.fskit.fsmodule`(`ntfs3g/ntfs3g.entitlements`)。
macOS(AMFI)只有在该权限被描述文件授权后才会加载扩展。在**自动签名**、团队 `529LJDH392`
下,只有当该团队的 App ID 在 Apple 开发者门户里开通了 **FSKit File System Module** 能力时
才行。开通后,在 **系统设置 → 通用 → 登录项与扩展 → 文件系统扩展** 中启用该模块。

## 沙盒与挂载

在 macOS 26.5 的沙盒构建上验证过,实际情况比最初设想的更窄:

- **自动挂载是主路径。** 系统通过扩展的 `FSMediaTypes` 把 NTFS 磁盘以读写方式自动挂载到
  `/Volumes`——无需应用进程、无需挂载权限。完全可用。
- **macOS 26 上沙盒应用无法手动挂载第三方 FSKit 卷。** DiskArbitration 挂载会返回
  `kDAReturnNotPrivileged`。`com.apple.developer.fskit.mount` 权限 + `FSClient.mountSingleVolume`
  **只在 macOS 27** 才授权手动挂载,而且即便在 27 上目标也**只能是 `/Volumes`**。
- **`mount -F -t xntfs …` 会失败**(“Probing resource: Permission denied”)。可用的命令行路径是
  **`diskutil mount`**,它经由 `diskarbitrationd`——和自动挂载同一条路。
- **无法挂载到自定义文件夹。** 扩展声明了 `FSRequiresSecurityScopedPathURLResources`,其沙盒
  只能访问 `/Volumes`(由 `diskarbitrationd` 拥有)和自身临时路径(如 `/tmp`)。任意文件夹需要
  一个安全作用域授权,而终端命令给不了、应用内路径也给不了(26 上无权、27 上只能 `/Volumes`)。
- **应用从不 shell 出去。** 沙盒拦截 `Process`,所以 `hdiutil`(附加/分离)和 27 之前的
  `diskutil mount` 都以**可复制的终端命令**交给用户运行。

所以:自动挂载到处可用;手动挂载在 macOS 27 上是应用内(→ `/Volumes`)、在 macOS 26 上是
可复制的 `diskutil mount` 命令;映像附加/分离始终是可复制的 `hdiutil` 命令。

> 这是*技术*能力结论;App Review 是另一道独立的政策关卡。

## 目录结构

```
xntfs/                     应用 target(SwiftUI)
  xntfsApp.swift           @main App + Settings 场景
  ContentView.swift        设备/映像列表 + 详情,挂载/附加/分离操作
  MountSheet.swift         手动挂载(→ /Volumes,只读开关)
  CommandSheet.swift       附加/分离 sheet(AttachImageSheet:默认只读)
  CopyableCommand.swift    共享的「复制此终端命令」控件
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
