import Foundation
import CoreFoundation
import QuartzCore

/// 电池电流 / 电压 / 温度 / 瓦数。
///
/// 只走 IORegistry 的 AppleSmartBattery —— 不走 IOPS。
/// IOPS 那套（IOPSCopyPowerSourcesInfo/List/Description）在这台设备上
/// 会在 IOKit 内部 CFGetTypeID 处 SIGTRAP 崩溃（见 QFSpeed-2026-10-30 崩溃日志），
/// 而且它本来就是给 macOS 设计的。IORegistry 读属性没有类型转换，安全得多。
enum PowerSampler {

    struct Reading {
        var current: Double? = nil     // mA，绝对值
        var watt: Double? = nil        // W
        var temperature: Double? = nil // °C
    }

    // MARK: - IOKit 动态符号
    //
    // 不用 `import IOKit`：iOS SDK 里 IOKit 不是 Swift module，
    // 链接得上但 import 不到。全部 dlsym，且用包装类型持住句柄。

    private typealias ServiceMatchingFn  = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    private typealias GetMatchingFn      = @convention(c) (mach_port_t, UnsafeMutableRawPointer?) -> UInt32
    private typealias CreatePropFn       = @convention(c) (UInt32, UnsafeRawPointer?, UnsafeMutableRawPointer?, UInt32) -> UnsafeMutableRawPointer?
    private typealias ReleaseFn          = @convention(c) (UInt32) -> kern_return_t

    private struct Symbols {
        var matching: ServiceMatchingFn?
        var getService: GetMatchingFn?
        var createProp: CreatePropFn?
        var release: ReleaseFn?

        init() {
            guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return }
            // dlsym 返回的指针必须活到进程结束，这里故意不 dlclose。
            func sym<T>(_ name: String, _ : T.Type) -> T? {
                guard let p = dlsym(h, name) else { return nil }
                return unsafeBitCast(p, to: T.self)
            }
            matching   = sym("IOServiceMatching", ServiceMatchingFn.self)
            getService = sym("IOServiceGetMatchingService", GetMatchingFn.self)
            createProp = sym("IORegistryEntryCreateCFProperty", CreatePropFn.self)
            release    = sym("IOObjectRelease", ReleaseFn.self)
        }
    }

    private static let symbols = Symbols()

    // MARK: - 缓存
    //
    // 每帧都读 IORegistry 太浪费，500ms 一次足够，悬浮条看不出差别。
    private static var cached = Reading()
    private static var cachedAt: CFTimeInterval = 0
    private static let ttl: CFTimeInterval = 0.5

    static func read() -> Reading {
        let now = CACurrentMediaTime()
        if now - cachedAt < ttl { return cached }
        cached = query()
        cachedAt = now
        return cached
    }

    // MARK: - 实际读取

    private static func query() -> Reading {
        var out = Reading()
        let s = symbols
        guard let matching = s.matching,
              let getService = s.getService,
              let createProp = s.createProp,
              let release = s.release else { return out }

        // IOServiceMatching 返回 +1 的 CFMutableDictionary。
        // IOServiceGetMatchingService 会 **消耗** 这个引用（文档明确写 "consumes a reference"），
        // 所以这里绝对不能让 ARC 接管 —— 否则 double free。
        let dictPtr: UnsafeMutableRawPointer? = "AppleSmartBattery".withCString { matching($0) }
        guard let dictPtr else { return out }

        let svc = getService(0 /* kIOMasterPortDefault */, dictPtr)
        guard svc != 0 else { return out }
        defer { _ = release(svc) }

        let allocator = kCFAllocatorDefault
        let utf8 = CFStringEncoding(kCFStringEncodingUTF8)

        func num(_ keyName: String) -> Double? {
            let ptr = keyName.withCString { cstr -> UnsafeMutableRawPointer? in
                // CFStringCreateWithCString 是 +1，用完必须 CFRelease，
                // 否则每次采样泄漏一个 CFString（一秒两次 × 一直运行 = 可观）。
                guard let key = CFStringCreateWithCString(allocator, cstr, utf8) else { return nil }
                defer { CFRelease(key) }
                return createProp(svc, Unmanaged.passUnretained(key).toOpaque(), allocator, 0)
            }
            guard let ptr else { return nil }
            // IORegistryEntryCreateCFProperty 是 Copy 语义 → +1
            let cfv = Unmanaged<CFTypeRef>.fromOpaque(ptr).takeRetainedValue()
            guard CFGetTypeID(cfv) == CFNumberGetTypeID() else { return nil }
            return (cfv as? NSNumber)?.doubleValue
        }

        // Amperage: 有符号，负=放电。界面上显示绝对值。
        if let amp = num("Amperage"), amp != 0 {
            out.current = abs(amp)
        }
        let volt = num("Voltage")   // mV
        if let mA = out.current {
            let mV = volt ?? 3850
            out.watt = mA / 1000.0 * (mV / 1000.0)
        }

        // Temperature 单位 1/100 °C；很多机型没有这个键 → nil，不编造
        if let t = num("Temperature"), t > 0, t < 15000 {
            out.temperature = t / 100.0
        }

        return out
    }
}
