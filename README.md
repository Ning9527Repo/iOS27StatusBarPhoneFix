# iOS27StatusBar Phone Fix

作者：Ning&半生年华&yaowell&Benja Guo

针对 iOS 17.2.1 RootHide 手机 SpringBoard 的 iOS27 状态栏持续刷新补丁。

## 目标

- 普通手机状态栏与手机控制中心都持续应用原版 27 信号样式。
- 控制中心晚创建/切换窗口后不退回原生双卡竖条。
- Wi-Fi 按系统真实状态刷新；不伪造联网状态。
- 不需要注销或重启 SpringBoard 才生效。
- 不涉及 CarPlay。

## 实现范围

原版视觉库 `iOS27StatusBar.dylib` 保持字节不变，来源包固定为 `vendor/statusbar-1.2-1.deb`，SHA-256：

`b0004cd4fda700e66d5f9ea7f454576c1a3da40fe08df900987efce8ee86dde6`

其中原始视觉 dylib SHA-256：

`709baf93799bf42d9adb5efcc389e290f538aaf8c6d697a386d58481c8c83a77`

新增 `PhoneLifecycleFix.dylib`，只加载到 `com.apple.springboard`：

- 按 fat slice UUID、`__TEXT,__text` 尺寸和 SHA-256 指纹确认原库版本；不匹配时安全跳过。
- 直接调用已核对的原版 Wi-Fi、单卡蜂窝、双卡蜂窝渲染入口。
- 枚举所有现有 UIApplication/UIScene 窗口，并监听窗口出现、App 激活、Scene 激活。
- 对晚创建的信号视图补充生命周期接管；仅处理 Signal/Wi-Fi/Cellular 家族。
- 只恢复原版关联的替换 UIImageView；不解除宿主或祖先的系统隐藏，不伪造 Wi-Fi 连接。
- Class/selector 去重、直接调用捕获的原 IMP、主线程合并刷新和重入保护。

这是针对已核对 1.2-1 二进制的版本绑定补丁，不是通用的任意状态栏框架。

## 构建

GitHub Actions 只有 `workflow_dispatch`，源码 push 不自动触发构建。macOS runner 使用 Xcode/iPhoneOS SDK，独立编译 arm64 与 arm64e companion，并生成两个 deb：

- `iphoneos-arm64`：RootHide 原始 `Library/...` 布局，companion 为真 arm64。
- `iphoneos-arm64e`：RootHide 原始 `Library/...` 布局，companion 为真 arm64e，Mach-O subtype `0x80000002`。

构建命令：

```sh
python3 build.py
```

本地源码检查：

```sh
python3 tools/vendor_map.py
python3 tests/check.py
```

构建、安装、注入和真机运行验证彼此独立。当前源码验证不等于已完成真机验证。
