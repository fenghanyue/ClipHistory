import CoreGraphics
import Foundation
import Testing
@testable import ClipCore

@Suite("面板大小：夹取、弹出尺寸、记忆")
struct PanelSizeTests {
    let minimum = CGSize(width: 300, height: 320)
    let normal = CGSize(width: 400, height: 460)
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test("大小在范围内：原样保留")
    func clampKeepsSizeInRange() {
        let size = CGSize(width: 520, height: 700)
        #expect(PanelPlacement.clampedSize(size, minimum: minimum, visibleFrame: screen) == size)
    }

    @Test("比最小尺寸小：补到最小尺寸，宽高分别处理")
    func clampRaisesToMinimum() {
        #expect(PanelPlacement.clampedSize(CGSize(width: 200, height: 100), minimum: minimum, visibleFrame: screen)
            == CGSize(width: 300, height: 320))
        #expect(PanelPlacement.clampedSize(CGSize(width: 200, height: 600), minimum: minimum, visibleFrame: screen)
            == CGSize(width: 300, height: 600))
    }

    @Test("比屏幕大（在大显示器上调的，换到小屏幕）：缩到屏幕可见区域大小")
    func clampShrinksToScreen() {
        #expect(PanelPlacement.clampedSize(CGSize(width: 2000, height: 1500), minimum: minimum, visibleFrame: screen)
            == CGSize(width: 1440, height: 875))
    }

    @Test("屏幕比最小尺寸还小：以屏幕为准")
    func clampTinyScreen() {
        let tiny = CGRect(x: 0, y: 0, width: 280, height: 260)
        #expect(PanelPlacement.clampedSize(normal, minimum: minimum, visibleFrame: tiny) == CGSize(width: 280, height: 260))
    }

    @Test("弹出：没保存过大小就用默认大小，位置和以前一样在鼠标右下方")
    func frameWithoutSavedSize() {
        let frame = PanelPlacement.frame(
            mouse: CGPoint(x: 500, y: 600), savedSize: nil, defaultSize: normal, minimumSize: minimum, visibleFrame: screen)
        #expect(frame == CGRect(x: 508, y: 132, width: 400, height: 460))
    }

    @Test("弹出：用上次保存的大小，靠边时按这个大小翻到另一侧")
    func frameUsesSavedSize() {
        let saved = CGSize(width: 600, height: 700)
        let frame = PanelPlacement.frame(
            mouse: CGPoint(x: 1300, y: 600), savedSize: saved, defaultSize: normal, minimumSize: minimum, visibleFrame: screen)
        // 右边放不下 600 宽 → 放到鼠标左边；下面放不下 700 高 → 放到鼠标上面，再夹进屏幕
        let expectedX: CGFloat = 1300 - 8 - 600
        #expect(frame.size == saved)
        #expect(frame.origin.x == expectedX)
        #expect(screen.contains(frame))
    }

    @Test("弹出：保存的大小比当前屏幕大 → 缩到屏幕里，整个面板都在屏幕内")
    func frameSavedSizeLargerThanScreen() {
        let small = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let frame = PanelPlacement.frame(
            mouse: CGPoint(x: 640, y: 360), savedSize: CGSize(width: 2000, height: 1500),
            defaultSize: normal, minimumSize: minimum, visibleFrame: small)
        #expect(frame.size == CGSize(width: 1280, height: 720))
        #expect(small.contains(frame))
    }

    // MARK: - 记忆

    /// 每个测试用独立的偏好设置域：不碰真实设置，测试之间也互不影响
    func withTemporaryDefaults(_ body: (UserDefaults) -> Void) {
        let name = "PanelSizeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test("从没保存过 → nil")
    func nothingSaved() {
        withTemporaryDefaults { defaults in
            #expect(PanelSizeStore(defaults: defaults).load() == nil)
        }
    }

    @Test("保存后能读回；重新创建一个 store（相当于重启 App）也读得到；新值覆盖旧值")
    func saveAndLoad() {
        withTemporaryDefaults { defaults in
            PanelSizeStore(defaults: defaults).save(CGSize(width: 512.5, height: 640))
            #expect(PanelSizeStore(defaults: defaults).load() == CGSize(width: 512.5, height: 640))
            PanelSizeStore(defaults: defaults).save(CGSize(width: 420, height: 480))
            #expect(PanelSizeStore(defaults: defaults).load() == CGSize(width: 420, height: 480))
        }
    }

    @Test("不合法的大小（0、负数、NaN、无穷）不保存，之前存的保留")
    func invalidSizeIgnored() {
        withTemporaryDefaults { defaults in
            let store = PanelSizeStore(defaults: defaults)
            store.save(CGSize(width: 500, height: 600))
            for bad in [CGSize(width: 0, height: 600), CGSize(width: -5, height: 600), CGSize(width: 500, height: 0),
                        CGSize(width: CGFloat.nan, height: 600), CGSize(width: 500, height: CGFloat.infinity)] {
                store.save(bad)
            }
            #expect(store.load() == CGSize(width: 500, height: 600))
        }
    }

    @Test("偏好设置里已经是不合法的值（被手改、被别的版本写坏）→ 当作没保存过")
    func corruptedValuesTreatedAsMissing() {
        withTemporaryDefaults { defaults in
            defaults.set(-100.0, forKey: PanelSizeStore.widthKey)
            defaults.set(600.0, forKey: PanelSizeStore.heightKey)
            #expect(PanelSizeStore(defaults: defaults).load() == nil)
            defaults.set(Double.nan, forKey: PanelSizeStore.widthKey)
            #expect(PanelSizeStore(defaults: defaults).load() == nil)
            // 只存了一半（另一个键缺失）也不能当成有效
            defaults.removeObject(forKey: PanelSizeStore.heightKey)
            defaults.set(500.0, forKey: PanelSizeStore.widthKey)
            #expect(PanelSizeStore(defaults: defaults).load() == nil)
        }
    }
}
