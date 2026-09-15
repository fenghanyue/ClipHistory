import AppKit

// 程序入口：设为后台 App（不显示 Dock 图标，只在菜单栏显示）
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
