# Pills iOS — 签名、归档与上架指引

本文件只作**操作指引**，不改动仓库现有配置。所有需要在 `project.yml` / `Info.plist` 中落地的项都以“待办”形式列出，由你在准备好开发者账号信息后再手动确认执行。

当前基线（来自 `project.yml`）：

| 项 | 值 |
| --- | --- |
| Bundle ID | `xyz.blueping.pills` |
| 部署目标 | iOS 17.0 |
| MARKETING_VERSION | 1.0.0 |
| CURRENT_PROJECT_VERSION | 1 |
| DEVELOPMENT_TEAM | `G7T8643585`（已同步至 `project.yml` 与 `project.pbxproj` 三个 app target 配置） |
| 已声明能力 | Sign in with Apple（`Pills/Pills.entitlements`） |
| 已声明用途字符串 | `NSMicrophoneUsageDescription`、`NSSpeechRecognitionUsageDescription` |

---

## 1. 前置条件

1. 一个已加入 **Apple Developer Program** 的付费账号（个人或组织）。
2. 拿到该账号的 **Team ID**（10 位字母数字，登录 <https://developer.apple.com/account> → Membership details 可见）。
3. 本机 Xcode 已登录同一 Apple ID（Xcode → Settings → Accounts）。
4. 组织账号还需要 **D-U-N-S 编号** 与法人信息（个人账号可跳过）。

> 说明：Sign in with Apple 需要一个付费开发者账号才能在真机 / App Store 构建中生效；模拟器可用本地桩验证流程，但上架前必须用真实账号跑通。

---

## 2. 注册 App ID 与能力

在 <https://developer.apple.com/account/resources> 中确认：

1. **Identifiers** 里存在 App ID `xyz.blueping.pills`（Bundle ID 显式，非通配）。
2. 该 App ID 勾选了 **Sign In with Apple** 能力（与 `Pills.entitlements` 一致）。
3. 若后续要接推送，再单独勾选 Push Notifications 并生成 APNs 密钥（当前代码未使用推送，可跳过）。

Xcode 开启“Automatically manage signing”后，上述注册通常会自动完成。

---

## 3. 配置签名（二选一）

### 方案 A — Xcode 自动签名（推荐首次上架）

1. `open Pills.xcodeproj`
2. 选中 **Pills** target → **Signing & Capabilities**。
3. 勾选 **Automatically manage signing**，在 **Team** 下拉选择你的开发者账号。
4. Xcode 会自动生成 / 匹配开发证书、分发证书与描述文件。

> 注意：本仓库用 **XcodeGen** 生成工程。若在 Xcode 里手动改了签名，下次 `xcodegen generate` 会覆盖。因此手动方案只适合“临时打一次包”，长期请把 Team ID 写进 `project.yml`（见方案 B）。

### 方案 B — 写入 `project.yml`（长期可复现，**已落地**）

> 现状：Team ID `G7T8643585` 已同步进 `project.yml` 的 `targets.Pills.settings.base.DEVELOPMENT_TEAM`，与 `project.pbxproj`（三个 app target 配置）一致。因此再跑 `xcodegen generate` 不会抹掉 Team ID，签名配置可复现。

把 `targets.Pills.settings.base.DEVELOPMENT_TEAM` 设为你的 10 位 Team ID，再 `xcodegen generate`。可选一并加入：

```yaml
    settings:
      base:
        DEVELOPMENT_TEAM: "G7T8643585"   # ← 当前使用的 Team ID
        CODE_SIGN_STYLE: Automatic
```

> 这一步是**待办**，按你之前的选择本次不自动改动。Team ID 属于账号信息，不应硬编码进公共仓库历史；若仓库是私有的可以接受，否则建议用 `xcconfig` 或 CI 变量注入。

---

## 4. 归档（Archive）

### 命令行

```bash
cd /Users/ben/projects/PillsIOS

# 1) 归档（Release 配置，指向生产 API）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project Pills.xcodeproj -scheme Pills \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/Pills.xcarchive \
  archive

# 2) 导出 IPA（App Store 分发）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -exportArchive \
  -archivePath build/Pills.xcarchive \
  -exportPath build/ipa \
  -exportOptionsPlist ExportOptions.plist
```

`ExportOptions.plist` 关键字段（App Store 上传）：

```xml
<key>method</key>            <string>app-store</string>
<key>teamID</key>            <string>G7T8643585</string>
<key>signingStyle</key>      <string>automatic</string>
<key>uploadSymbols</key>     <true/>
<key>destination</key>       <string>upload</string>
```

> 归档必须用 `-configuration Release`，这样 `PILLS_API_ENVIRONMENT=Production`、`PILLS_API_BASE_URL=https://pills.blueping.xyz` 才会被注入（见 `project.yml` 的 configs 段）。Debug 指向 `127.0.0.1:8001`，**不要**用它打包上架。

### Xcode GUI

Product → Destination 选 **Any iOS Device (arm64)** → Product → **Archive** → Organizer 里 **Distribute App → App Store Connect**。

---

## 5. 上传

- **Xcode Organizer**：Window → Organizer → 选中 archive → Distribute App。
- **命令行**：`xcrun altool --upload-app -f build/ipa/Pills.ipa -t ios -u <apple-id> -p <app-specific-password>`，或较新的 `xcrun notarytool` / Transporter app。

上传后在 **App Store Connect** 里把该构建绑定到一个 App 版本，填写元数据后提交审核。

---

## 6. App Store 提交前检查清单

以下项**当前仓库尚未落地**，属于上架前必须补齐的“待办”（本次按你的选择只出指引，不改代码）：

### 6.1 出口合规（Export Compliance）

App 使用 HTTPS / Sign in with Apple 等标准加密。为避免每次提交都被追问，需在 `Info.plist` 增加：

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

含义：只使用豁免类加密（系统 TLS、标准鉴权），不涉及自研 / 非豁免算法。**待办**：确认后加入 `project.yml` 的 `info.properties` 并重新生成。

### 6.2 隐私清单（Privacy Manifest, `PrivacyInfo.xcprivacy`）

自 2024 年春季起，App Store 对新提交要求隐私清单。本 App 需要声明：

- **数据收集类型**：与 Sign in with Apple 关联的姓名 / 邮箱、健康与健身类数据（呼吸练习记录）、用户内容（AI 聊天消息）。
- **必需原因 API（Required Reason API）**：若代码或依赖读取文件时间戳、磁盘空间、系统启动时间、键盘列表等，需声明对应 reason。当前 App 主要用 `UserDefaults` / SwiftData / Keychain，需逐项核对 Apple 公布的 API 清单。
- **跟踪域名 / 第三方 SDK**：当前无第三方分析 SDK，若后端接入需补充。

**待办**：新建 `Pills/PrivacyInfo.xcprivacy`，在 Xcode → target → Privacy 里编辑，或直接放一个 XML 清单文件并纳入 bundle。

### 6.3 App 隐私“营养标签”

在 App Store Connect → App Privacy 中如实填写数据收集与用途，需与 6.2 的清单一致。

### 6.4 权限用途字符串（已具备，复核文案）

`Info.plist` 已有：

- `NSMicrophoneUsageDescription` — “用于语音输入，将语音转换为文字发送给 AI 教练”
- `NSSpeechRecognitionUsageDescription` — 同上

审核会核对文案与实际用途是否相符；当前语音输入功能确实用到麦克风 + 语音识别，文案合规。**无需改动**，仅复核。

### 6.5 版本号策略

- 首次上架：`MARKETING_VERSION=1.0.0`、`CURRENT_PROJECT_VERSION=1`（现状即可）。
- 每次重新上传同一营销版本的构建，必须递增 `CURRENT_PROJECT_VERSION`（build number）。

### 6.6 图标与启动屏

- `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` 已配置——确认 `Assets.xcassets/AppIcon` 提供了 1024×1024 无透明通道图标及各尺寸。
- 启动屏用 `UILaunchScreen`（`LaunchImage` + `AccentColor`），确认资源存在。

### 6.7 无障碍（本次已落地代码）

本 pass 已完成无障碍核心改造，无需在提交清单里额外操作，仅记录以便审核沟通：

- VoiceOver：图标按钮补充标签、装饰性图片 `accessibilityHidden`、卡片 / 行合并为单一元素。
- 触控目标：麦克风、发送、关闭错误提示、重试等按钮最小 44×44pt。
- Dynamic Type：聊天输入栏用 `@ScaledMetric` 随字号缩放。
- Reduce Motion：呼吸节奏动画为“必要动画”保留；打字指示器、横幅 / 气泡过渡等非必要动画在开启减弱动态效果时降级。

---

## 7. 上架前最终验证

```bash
cd /Users/ben/projects/PillsIOS

# 单元测试（当前 177 项全绿）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project Pills.xcodeproj -scheme Pills \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Release 编译（真机 generic 目标）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild build -project Pills.xcodeproj -scheme Pills \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

真机手动冒烟：Sign in with Apple 登录、呼吸练习完整跑一轮并落库、AI 聊天收发、语音输入、历史记录分页、离线横幅与恢复。

---

## 待办汇总（本次未执行）

1. 填入 Team ID：**已完成** — `G7T8643585` 已同步至 `project.yml` 与 `project.pbxproj`（三个 app target 配置），`xcodegen generate` 不会抹掉（见方案 B）。
2. `Info.plist` 增加 `ITSAppUsesNonExemptEncryption=false`。
3. 新建并填写 `PrivacyInfo.xcprivacy` 隐私清单。
4. App Store Connect 填写隐私营养标签与元数据。
5. 确认 AppIcon / LaunchImage 资源齐全。
6. Release 归档 → 导出 IPA → 上传 → 绑定版本 → 提交审核。
