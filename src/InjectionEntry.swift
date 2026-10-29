import UIKit

/// 进程注入入口。
///
/// 这个 dylib 会被 TrollFools（或越狱环境下 Tweak 注入）加载进 SpringBoard 进程。
/// 一旦在 SpringBoard 里跑起来，我们建的 UIWindow 就天然处在系统 UI 层，
/// 覆盖所有 App —— 这才是真正的「系统级浮窗」。
///
/// 注意：不要在这里做任何 UIView 操作或取 UIApplication.shared.keyWindow，
/// 因为 dylib 加载时机（constructor）早于 SpringBoard 建好窗口，拿到的是 nil。
/// 一律丢到主队列下一拍。
@_cdecl("qfspeed_inject_entry")
public func qfspeedInjectEntry() {
    DispatchQueue.main.async {
        startWhenReady(attempt: 0)
    }
}

private func startWhenReady(attempt: Int) {
    // SpringBoard 起来到有 keyWindow 需要一点时间，最多等 5 秒（25 × 0.2s）
    guard attempt < 25 else {
        NSLog("[QFSpeed] SpringBoard scene 一直没就绪，放弃挂载")
        return
    }

    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                 ?? scenes.first
    else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            startWhenReady(attempt: attempt + 1)
        }
        return
    }

    FloatingWindowManager.shared.show()
    NSLog("[QFSpeed] 已挂载到 SpringBoard（第 \(attempt + 1) 次尝试）")

    // 记一笔，方便我们在设备日志里确认走的是注入路径而不是独立 App
    SpringBoardWindowHost.shared.markInjected()
}
