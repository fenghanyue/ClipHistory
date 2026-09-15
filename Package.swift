// swift-tools-version:6.0
// 用 6.0 格式清单，但通过 swiftLanguageModes 保持 Swift 5 语言模式，
// 避开 Swift 6 严格并发检查对 AppKit/Carbon 代码的大量报错。
// 注意：本机请用 scripts/swift.sh 代替 swift 命令（自动绕过命令行工具的升级残留文件，build_app.sh 已在用）。
import PackageDescription

let package = Package(
    name: "ClipHistory",
    platforms: [.macOS(.v14)],
    targets: [
        // 纯逻辑库：配置、日志、过滤规则、存储（不含界面，可单元测试）
        .target(name: "ClipCore"),
        // App 本体：菜单栏、快捷键、弹出列表、自动输入
        .executableTarget(name: "ClipHistory", dependencies: ["ClipCore"]),
        // 单元测试（Swift Testing）：scripts/swift.sh test --disable-xctest
        .testTarget(name: "ClipCoreTests", dependencies: ["ClipCore"]),
    ],
    swiftLanguageModes: [.v5]
)
