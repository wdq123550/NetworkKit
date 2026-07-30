//
//  NetworkConfiguration.swift
//  NetworkKit
//
//  全局网络配置（默认主机、超时、拦截器、外层字段映射等）
//

import Foundation
import Observation
import SmartCodable

@Observable
public final class NetworkConfiguration {
    // MARK: - 存储属性
    /// 单例实例
    public static let shared = NetworkConfiguration()
    private init() {}
    /// 默认主机地址（含 scheme，如 "https://api.example.com"）
    public var baseHost: String = ""
    /// 默认请求头（每个请求会先铺这一层，再叠加请求自身的 header）
    public var defaultHeaders: [String: String] = ["Content-Type": "application/json"]
    /// 默认超时时间（秒）
    public var defaultTimeout: TimeInterval = 15
    /// 默认外层字段映射与成功判定
    public var defaultEnvelope: ResponseEnvelope = ResponseEnvelope()
    /// 默认模型解码选项（键名策略、日期策略、Data 策略、浮点数策略），透传给 SmartCodable
    /// 默认为空集合，即按模型属性名原样匹配 JSON 字段；后端若是下划线命名，在这里设 `.key(.fromSnakeCase)` 即可全局生效
    public var defaultDecodingOptions: Set<SmartDecodingOption> = []
    /// 默认重试策略
    public var defaultRetryPolicy: RetryPolicy = .none
    /// 全局请求拦截器（对所有未忽略全局拦截器的请求生效，先于请求自身拦截器执行）
    @ObservationIgnored public var globalRequestInterceptors: [RequestInterceptor] = []
    /// 全局返回拦截器（先于请求自身拦截器执行）
    @ObservationIgnored public var globalResponseInterceptors: [ResponseInterceptor] = []
    /// 是否打印调试日志（沿用项目 [debugLog] 风格）
    public var enableLog: Bool = false
    /// 解析诊断日志的输出出口；为 nil 时仅在 DEBUG 下按 [debugLog] 风格打印
    /// 宿主 App 有统一日志设施时在这里接管。注意诊断日志可能来自任意一处 SmartCodable 解析，不限于本库发起的请求
    @ObservationIgnored public var decodingDiagnosticsHandler: ((String) -> Void)?
    /// 底层会话（默认用 .default 配置，可整体替换）
    @ObservationIgnored public var session: URLSession = .shared
}

// MARK: - 计算属性
extension NetworkConfiguration {
    /// 模型解析的字段级诊断开关
    ///
    /// SmartCodable 的容错是静默的：某个字段类型不符或缺失时，它会自动转换或填默认值，不会报错。
    /// 打开该开关后会逐字段输出诊断信息（如「age 期望 Int 实际 String，已自动转换」
    /// 「email 字段不存在，使用默认值」），便于发现后端字段悄悄变更导致的模型空值。
    ///
    /// 底层的 SmartSentinel 是 SmartCodable 的全局设施，因此开关一旦打开，App 内所有经 SmartCodable
    /// 的解析都会产生诊断日志，并不限于本库发起的请求；日志去向由 `decodingDiagnosticsHandler` 决定。
    ///
    /// 该开关不持有本地状态，读写直接作用于 SmartSentinel，避免两处状态不同步。
    public var enableDecodingDiagnostics: Bool {
        get { SmartSentinel.debugMode != .none }
        set {
            guard newValue else {
                SmartSentinel.debugMode = .none
                return
            }
            SmartSentinel.debugMode = .verbose
            // 回调里每次都重新读取输出出口，故设置 handler 与打开开关的先后顺序不影响结果
            SmartSentinel.onLogGenerated { diagnosticLog in
                NetworkConfiguration.shared.emitDecodingDiagnostics(diagnosticLog)
            }
        }
    }
}

// MARK: - 方法
extension NetworkConfiguration {
    /// 输出一条模型解析诊断日志：设置了自定义出口就交给它，否则在 DEBUG 下按 [debugLog] 风格打印
    /// - Parameter diagnosticLog: SmartSentinel 生成的多行诊断文本
    private func emitDecodingDiagnostics(_ diagnosticLog: String) {
        guard let decodingDiagnosticsHandler else {
            #if DEBUG
            print("[debugLog] SmartCodable 解析诊断\n\(diagnosticLog)")
            #endif
            return
        }
        decodingDiagnosticsHandler(diagnosticLog)
    }
}
