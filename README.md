# ClipHistory

macOS 菜单栏剪贴板历史工具，本地记录、⌥⌘V 弹出选择、自动输入。

## 功能

- 后台持续记录剪贴板历史(文本 / 图片 / 带格式内容如 HTML 富文本)，可随时暂停
- ⌥⌘V 在鼠标位置弹出历史列表，"最近"/"收藏"两个标签页，选中后自动输入到当前光标处
- 菜单栏图标：暂停/恢复记录、查看条数统计、清空历史(保留收藏)、打开调试日志
- 隐私相关的过滤规则：跳过密码类 App(1Password/Bitwarden/钥匙串等)、跳过标记为"机密/临时/自动生成"的内容、跳过文件复制(不误记文件名)
- 数据完全存本地(`~/Library/Application Support/ClipHistory/`)，不联网、不上传

## 环境要求

- macOS 14+，Apple 芯片(M 系列)
- Swift 6 工具链(实际以 Swift 5 语言模式编译，见 `Package.swift`)

## 构建与运行

编译 / 测试用 `scripts/swift.sh` 代替 `swift` 命令(说明见脚本内注释，绕过本机命令行工具残留文件的问题)：

```sh
scripts/swift.sh build
scripts/swift.sh test --disable-xctest   # 单元测试用 Swift Testing
```

打包安装到本机：

```sh
scripts/build_app.sh   # 编译 release、组装签名、装到 ~/Applications 并启动
```

打包分发用 DMG(自签名，未经苹果公证，仅 Apple 芯片；产物在 `dist/`)：

```sh
scripts/make_dmg.sh
```

## 首次使用

1. 安装后在「系统设置 → 隐私与安全性」允许打开(未做付费开发者认证)
2. 在「系统设置 → 隐私与安全性 → 辅助功能」里给 ClipHistory 开权限(用于自动输入)
3. 正常复制即可自动记录；输入框内按 ⌥⌘V 弹出历史，选中即自动粘贴

## 项目结构

- `Sources/ClipCore/`：纯逻辑库，无界面依赖，可单元测试(配置、采集过滤规则、SQLite 存储、图片/富文本存储等)
- `Sources/ClipHistory/`：App 本体(菜单栏、全局快捷键、弹出面板 UI、自动输入)
- `Tests/ClipCoreTests/`：`ClipCore` 的单元测试
- `Resources/`：`Info.plist`、App 图标
- `scripts/`：构建/打包/图标生成脚本

## 配置

可调参数集中在 `Sources/ClipCore/Config.swift`(采集大小上限、保留条数上限、格式白名单、密码类 App 名单等)，改动后重新运行 `scripts/build_app.sh` 生效。
