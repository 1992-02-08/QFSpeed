import UIKit

/// 把浮窗托管给 SpringBoard —— 这样它不再依附本 App 的 scene，
/// 切到任何 App / 回到桌面都保持可见。这是「系统级浮窗」的真正实现。
///
/// 原理：`SBSAccessibilityWindowHostingController` 是 SpringBoard 对
/// 「已签 com.apple.springboard.accessibility-window-hosting」的 App 开放的托管入口。
/// 把你窗口的 contextId 注册进去，SpringBoard 就会在**它自己的层级**里替你渲染这块内容，
/// 所以本 App 进后台也不影响显示。
///
/// 全部走 NSClassFromString + IMP 动态调用：
///   1. SpringBoardServices 没有 Swift modulemap，`import` 它编不过；
///   2. 这类私有类在不同系统版本上可能被移除，硬链接会导致启动即崩。
/// 动态调用最坏情况只是「找不到 → 降级」，不会崩。
final class SpringBoardWindowHost {

    static let shared = SpringBoardWindowHost()
    private init() {}

    /// 必须强引用，controller 释放后托管立即失效
    private var hosting: AnyObject?
    private(set) var contextID: UInt32 = 0
    private(set) var isHosted = false
    private(set) var wasInjected = false

    func markInjected() { wasInjected = true }

    /// 取 UIWindow 的私有 `_contextId`（SpringBoard 认的就是这个值）。
    /// 注意：不能自己随机生成 —— 必须是被托管窗口真实的 contextId，否则 SpringBoard 找不到要渲染的对象。
    private func contextID(of window: UIWindow) -> UInt32? {
        let sel = NSSelectorFromString("_contextId")
        guard window.responds(to: sel) else { return nil }
        // 不同系统版本 _contextId 的返回类型不同（unsigned int / unsigned long），
        // 按 UInt 取（64 位寄存器）再把低 32 位截出来，两种都对。
        typealias Fn = @convention(c) (AnyObject, Selector) -> UInt
        let fn = unsafeBitCast(window.method(for: sel), to: Fn.self)
        let raw = fn(window, sel)
        let cid = UInt32(truncatingIfNeeded: raw)
        return cid == 0 ? nil : cid
    }

    /// 把 window 托管给 SpringBoard。失败返回 false，调用方退回普通 UIWindow。
    @discardableResult
    func host(_ window: UIWindow) -> Bool {
        guard !isHosted else { return true }

        guard let cid = contextID(of: window) else {
            NSLog("[QFSpeed] 取不到 _contextId，降级为普通窗口")
            return false
        }

        guard let cls = NSClassFromString("SBSAccessibilityWindowHostingController") as? NSObject.Type else {
            NSLog("[QFSpeed] SBSAccessibilityWindowHostingController 不存在，降级")
            return false
        }

        let controller = cls.init()
        let sel = NSSelectorFromString("registerWindowWithContextID:")
        guard controller.responds(to: sel) else {
            NSLog("[QFSpeed] registerWindowWithContextID: 不可用，降级")
            return false
        }

        // -registerWindowWithContextID:(unsigned int)
        typealias RegisterFn = @convention(c) (AnyObject, Selector, UInt32) -> Void
        let fn = unsafeBitCast(controller.method(for: sel), to: RegisterFn.self)
        fn(controller, sel, cid)

        hosting = controller
        contextID = cid
        isHosted = true
        NSLog("[QFSpeed] 已托管给 SpringBoard, contextID=\(cid)")
        return true
    }

    func unhost() {
        guard isHosted, let controller = hosting else { return }
        let sel = NSSelectorFromString("unregisterWindowWithContextID:")
        if controller.responds(to: sel) {
            typealias Fn = @convention(c) (AnyObject, Selector, UInt32) -> Void
            let fn = unsafeBitCast(controller.method(for: sel), to: Fn.self)
            fn(controller, sel, contextID)
        }
        hosting = nil
        isHosted = false
        NSLog("[QFSpeed] 已取消 SpringBoard 托管")
    }
}
