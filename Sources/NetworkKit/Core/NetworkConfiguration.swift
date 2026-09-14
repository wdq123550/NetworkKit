//
//  NetworkConfiguration.swift
//  NetworkKit
//
//  网络配置：默认主机、超时、拦截器、外层字段映射、事件监听等。
//  可以只用 `shared` 一套，也可以为不同后端各建一份，由请求的 `configuration` 指定
//

import Foundation
import SmartCodable

//MARK: - NetworkConfiguration
/// 网络配置。所有属性都应在 App 启动时配置好，运行期不要频繁改动
///
/// 一个 App 往往同时对接多个后端（业务网关、配置中心、审核服务、第三方时间服务……），它们的主机、签名、外层壳各不相同。
/// 这时不必全部塞进 `shared`：为每个后端建一份 `NetworkConfiguration`，请求重写 `configuration` 指向它，
/// 该后端的 host / 拦截器 / envelope / 超时就都有了归属，请求本身只剩 path 和参数
public final class NetworkConfiguration: @unchecked Sendable {
    //MARK: - 存储属性
    /// 默认配置实例
    public static let shared = NetworkConfiguration()
    /// 默认主机地址（含 scheme，如 "https://api.example.com"）
    public var baseHost: String = ""
    /// 默认请求头（每个请求会先铺这一层，再叠加请求自身的 header）
    public var defaultHeaders: [String: String] = ["Content-Type": "application/json"]
    /// 默认超时时间（秒）
    public var defaultTimeout: TimeInterval = 60
    /// 默认外层字段映射与成功判定
    public var defaultEnvelope: ResponseEnvelope = ResponseEnvelope()
    /// 默认模型解码选项（键名策略、日期策略、Data 策略、浮点数策略），透传给 SmartCodable
    /// 默认为空集合，即按模型属性名原样匹配 JSON 字段；后端若是下划线命名，在这里设 `.key(.fromSnakeCase)` 即可全局生效
    public var defaultDecodingOptions: Set<SmartDecodingOption> = []
    /// 默认重试策略
    public var defaultRetryPolicy: RetryPolicy = .none
    /// 默认可接受的 HTTP 状态码范围
    public var defaultAcceptableStatusCodes: Range<Int> = 200..<300
    /// URL query 与表单参数的编码选项
    public var queryEncoding: QueryEncodingOptions = QueryEncodingOptions()
    /// 全局请求拦截器（对所有未忽略全局拦截器的请求生效，先于请求自身拦截器执行）
    public var globalRequestInterceptors: [RequestInterceptor] = []
    /// 全局响应拦截器（先于请求自身拦截器执行）
    public var globalResponseInterceptors: [ResponseInterceptor] = []
    /// 请求生命周期事件监听（日志 / 埋点 / 耗时统计接在这里）
    public var eventMonitors: [NetworkEventMonitor] = []
    /// 是否在 DEBUG 下把请求生命周期打印到控制台（等价于挂一份 `ConsoleEventMonitor`）
    public var enableLog: Bool = false
    /// 底层会话（默认 `.shared`，可整体替换成自定义 URLSession）
    public var session: URLSession = .shared
    /// 文件下载的最大并发数
    public var maxConcurrentDownloads: Int = 3
    /// 全局的解析诊断状态（SmartSentinel 是进程级设施，所以放在类型上而不是实例上）
    private static let diagnosticsState = LockedValue(DiagnosticsState())

    /// 创建一份独立配置（默认值与 `shared` 相同）
    public init() {}
}

//MARK: - DiagnosticsState
private extension NetworkConfiguration {
    /// 解析诊断相关的全局状态
    struct DiagnosticsState {
        /// 宿主接管诊断输出的回调
        var handler: ((String) -> Void)?
        /// 最近一次 SmartSentinel 产生的诊断文本，解析失败时随错误带出
        var lastDiagnostics: String?
    }
}

//MARK: - 计算属性
extension NetworkConfiguration {
    /// 模型解析的字段级诊断开关（进程级，作用于 SmartCodable 的 SmartSentinel）
    ///
    /// SmartCodable 的容错是静默的：某个字段类型不符或缺失时，它会自动转换或填默认值，不会报错。
    /// 打开该开关后会逐字段输出诊断信息（如「age 期望 Int 实际 String，已自动转换」「email 字段不存在，使用默认值」），
    /// 便于发现后端字段悄悄变更导致的模型空值；同时 `NetworkError.decoding` 会带上最近一次诊断文本。
    ///
    /// 底层的 SmartSentinel 是进程级设施，所以开关一旦打开，App 内所有经 SmartCodable 的解析都会产生诊断日志，
    /// 并不限于本库发起的请求；日志去向由 `decodingDiagnosticsHandler` 决定。
    public static var isDecodingDiagnosticsEnabled: Bool {
        get { SmartSentinel.debugMode != .none }
        set {
            guard newValue else {
                SmartSentinel.debugMode = .none
                return
            }
            SmartSentinel.debugMode = .verbose
            // 回调里每次都重新读取输出出口，故设置 handler 与打开开关的先后顺序不影响结果
            SmartSentinel.onLogGenerated { diagnosticLog in
                NetworkConfiguration.emitDecodingDiagnostics(diagnosticLog)
            }
        }
    }
    /// 解析诊断日志的输出出口；为 nil 时仅在 DEBUG 下按 [debugLog] 风格打印。宿主 App 有统一日志设施时在这里接管
    public static var decodingDiagnosticsHandler: ((String) -> Void)? {
        get { diagnosticsState.value.handler }
        set { diagnosticsState.withValue { $0.handler = newValue } }
    }
    /// 最近一次解析诊断文本（仅在诊断开关打开时有值）
    static var lastDecodingDiagnostics: String? {
        diagnosticsState.value.lastDiagnostics
    }
    /// 本配置实际生效的事件监听列表：显式配置的 + `enableLog` 在 DEBUG 下带来的控制台日志
    var effectiveEventMonitors: [NetworkEventMonitor] {
        #if DEBUG
        guard enableLog else { return eventMonitors }
        return eventMonitors + [ConsoleEventMonitor()]
        #else
        return eventMonitors
        #endif
    }
}

//MARK: - 方法
extension NetworkConfiguration {
    /// 输出一条模型解析诊断日志：先记下来供解析错误携带，再交给自定义出口；没有出口则在 DEBUG 下打印
    /// - Parameter diagnosticLog: SmartSentinel 生成的多行诊断文本
    private static func emitDecodingDiagnostics(_ diagnosticLog: String) {
        let handler = diagnosticsState.withValue { state -> ((String) -> Void)? in
            state.lastDiagnostics = diagnosticLog
            return state.handler
        }
        guard let handler else {
            #if DEBUG
            print("[debugLog] SmartCodable 解析诊断\n\(diagnosticLog)")
            #endif
            return
        }
        handler(diagnosticLog)
    }

    /// 清空最近一次诊断文本，在每次解析前调用，避免把上一次的诊断错挂到本次错误上
    static func clearLastDecodingDiagnostics() {
        diagnosticsState.withValue { $0.lastDiagnostics = nil }
    }
}
