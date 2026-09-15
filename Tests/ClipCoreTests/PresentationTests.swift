import CoreGraphics
import Foundation
import Testing
@testable import ClipCore

@Suite("列表显示：相对时间、弹出位置")
struct PresentationTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    func describe(_ text: String) -> String {
        TimeText.describe(date(text), now: date("2026-09-14 15:00:00"), calendar: calendar)
    }

    @Test("相对时间")
    func relativeTime() {
        #expect(describe("2026-09-14 14:59:30") == "刚刚")
        #expect(describe("2026-09-14 15:00:10") == "刚刚") // 系统时钟往回调
        #expect(describe("2026-09-14 14:55:00") == "5 分钟前")
        #expect(describe("2026-09-14 12:00:00") == "3 小时前")
        #expect(describe("2026-09-13 22:30:00") == "昨天 22:30")
        #expect(describe("2026-09-01 08:05:00") == "9月1日 08:05")
        #expect(describe("2025-12-31 23:00:00") == "2025年12月31日")
    }

    let size = CGSize(width: 380, height: 440)
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test("弹出位置：默认在鼠标右下方")
    func placementDefault() {
        #expect(PanelPlacement.origin(mouse: CGPoint(x: 500, y: 600), size: size, visibleFrame: screen) == CGPoint(x: 508, y: 152))
    }

    @Test("弹出位置：靠右边翻到左边，靠下边翻到上面")
    func placementFlips() {
        #expect(PanelPlacement.origin(mouse: CGPoint(x: 1300, y: 600), size: size, visibleFrame: screen) == CGPoint(x: 912, y: 152))
        #expect(PanelPlacement.origin(mouse: CGPoint(x: 500, y: 100), size: size, visibleFrame: screen) == CGPoint(x: 508, y: 108))
        #expect(PanelPlacement.origin(mouse: CGPoint(x: 1400, y: 50), size: size, visibleFrame: screen) == CGPoint(x: 1012, y: 58))
    }

    @Test("弹出位置：屏幕比列表还小时，左上角可见")
    func placementTinyScreen() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 300)
        #expect(PanelPlacement.origin(mouse: CGPoint(x: 150, y: 150), size: size, visibleFrame: tiny) == CGPoint(x: 0, y: -140))
    }

    @Test("弹出位置：副屏坐标不从 0 开始")
    func placementSecondaryScreen() {
        let secondary = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(PanelPlacement.origin(mouse: CGPoint(x: -100, y: 500), size: size, visibleFrame: secondary) == CGPoint(x: -488, y: 52))
    }
}
