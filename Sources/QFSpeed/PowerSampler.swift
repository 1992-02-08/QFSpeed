import Foundation
import Darwin
import CoreFoundation
import QuartzCore

// MARK: - 电源信息采样（dlopen + dlsym）

/// 为什么不用 `import IOKit.ps`：
/// IOKit 在 **iOS SDK 里不提供 Swift module**（只有 macOS SDK 有），
/// 直接 import 会报 "No such module 'IOKit'"。私有的 `IOKit/ps/IOPowerSources.h`
/// 也不在 iOS SDK 的头文件搜索路径里。
///
/// 所以统一走 dlopen + dlsym：符号在运行时一定存在（dyld shared cache 里有），
/// 编译期不需要任何私有头文件，独立 App / 注入 dylib 都能编过。
/// 代价是全弱绑定 —— 拿不到就返回 nil，调用方必须接受"这项没值"。
enum PowerSampler {

    // MARK: 句柄

    private static let iokitHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
            ?? dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY)
    }()

    // MARK: C 函数签名
    //
    // 全部用 UnsafeRawPointer / UnsafePointer<CChar> 表达 CF 参数，
    // 不用 AnyObject —— @convention(c) 里放 CF 类类型容易踩 ABI 细节。

    private typealias CopyPowerSourcesInfoFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias CopyPowerSourcesListFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias GetPowerSourceDescriptionFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> UnsafeMutableRawPointer?

    private typealias IOServiceMatchingFn = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    private typealias IOServiceGetMatchingServiceFn = @convention(c) (
        mach_port_t, UnsafeMutableRawPointer?
    ) -> UInt32
    private typealias IORegistryCreateCFPropertyFn = @convention(c) (
        UInt32, UnsafeRawPointer?, UnsafeRawPointer?, UInt32
    ) -> Unmanaged<AnyObject>?
    private typealias IOObjectReleaseFn = @convention(c) (UInt32) -> kern_return_t

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = iokitHandle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    private static let copyInfo  = symbol("IOPSCopyPowerSourcesInfo",     as: CopyPowerSourcesInfoFn.self)
    private static let copyList  = symbol("IOPSCopyPowerSourcesList",     as: CopyPowerSourcesListFn.self)
    private static let getDesc   = symbol("IOPSGetPowerSourceDescription", as: GetPowerSourceDescriptionFn.self)

    private static let serviceMatching    = symbol("IOServiceMatching",               as: IOServiceMatchingFn.self)
    private static let getMatchingService = symbol("IOServiceGetMatchingService",      as: IOServiceGetMatchingServiceFn.self)
    private static let createCFProperty   = symbol("IORegistryEntryCreateCFProperty",  as: IORegistryCreateCFPropertyFn.self)
    private static let objectRelease      = symbol("IOObjectRelease",                 as: IOObjectReleaseFn.self)

    // MARK: 结果

    struct Reading {
        var current: Double?      // mA，放/充都取绝对值
        var watt: Double?         // W
        var temperature: Double?  // °C
    }

    /// 标称电压兜底：IOPS 不给 Voltage 时用它估算瓦数（锂电 3.87V 是合理中值）
    private static let nominalVoltage: Double = 3.87

    // MARK: 温度缓存
    //
    // IORegistry 查询比读 IOPS 慢，温度又是秒级缓变量，5 秒一次足够。
    private static var cachedTemp: Double?
    private static var cachedTempAt: CFTimeInterval = 0
    private static let tempTTL: CFTimeInterval = 5

    // MARK: 主入口

    static func read() -> Reading {
        var out = Reading()

        if let infoRaw = copyInfo?() {
            // IOPSCopy* 是 Copy 语义 → +1，交给 ARC 释放
            let info = Unmanaged<AnyObject>.fromOpaque(infoRaw).takeRetainedValue()

            if let listRaw = copyList?(infoRaw) {
                let listObj = Unmanaged<AnyObject>.fromOpaque(listRaw).takeRetainedValue()
                if let list = listObj as? [AnyObject] {
                    for src in list {
                        guard let descPtr = getDesc?(infoRaw, Unmanaged.passUnretained(src).toOpaque()) else { continue }
                        // "Get" 语义 → +0
                        let descObj = Unmanaged<AnyObject>.fromOpaque(descPtr).takeUnretainedValue()
                        guard let d = descObj as? [String: Any] else { continue }

                        var mA: Double?
                        if let n = d["Current"] as? NSNumber, n.doubleValue != 0 {
                            mA = abs(n.doubleValue)
                        }
                        var mV: Double?
                        if let n = d["Voltage"] as? NSNumber, n.doubleValue > 0 {
                            mV = n.doubleValue
                        }

                        out.current = mA
                        if let mA {
                            out.watt = mA / 1000.0 * ((mV ?? nominalVoltage) / 1000.0)
                        }
                        break
                    }
                }
            }
            _ = info  // 保证 ARC 活到 list 用完
        }

        out.temperature = batteryTemperature()
        return out
    }

    // MARK: 温度

    /// 只有 IORegistry 的 `AppleSmartBattery.Temperature` 能给出电池温度，单位 1/100 °C。
    /// 这个键在很多机型上根本不存在 —— 取不到就返回 nil，绝不用假值糊弄界面。
    private static func batteryTemperature() -> Double? {
        let now = CACurrentMediaTime()
        if now - cachedTempAt < tempTTL { return cachedTemp }

        cachedTemp = queryBatteryTemperature()
        cachedTempAt = now
        return cachedTemp
    }

    private static func queryBatteryTemperature() -> Double? {
        guard let matching = serviceMatching,
              let getService = getMatchingService,
              let createProp = createCFProperty,
              let release = objectRelease else { return nil }

        let dictPtr: UnsafeMutableRawPointer? = "AppleSmartBattery".withCString { matching($0) }
        guard let dictPtr else { return nil }

        // IOServiceMatching 返回 +1 的 CFMutableDictionary，而 IOServiceGetMatchingService
        // **会消耗掉这个引用**。所以这里绝对不能再用 ARC 接管一次 ——
        // 否则 ARC 释放一次、IOKit 内部也释放一次，直接过度释放崩溃。
        // 正确做法：原样把裸指针交过去，之后不再碰它。
        let service = getService(0, dictPtr)
        guard service != 0 else { return nil }
        defer { _ = release(service) }

        let key = "Temperature" as CFString
        guard let prop = createProp(
            service,
            Unmanaged.passUnretained(key).toOpaque(),
            nil,
            0
        )?.takeRetainedValue() as? NSNumber else { return nil }

        let celsius = prop.doubleValue / 100.0
        // 合理区间：0~120°C 之外认为读错了
        guard celsius > 0, celsius < 120 else { return nil }
        return celsius
    }
}
