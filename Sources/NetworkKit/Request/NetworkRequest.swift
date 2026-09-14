//
//  NetworkRequest.swift
//  NetworkKit
//
//  核心请求协议：一个对象遵守它即拥有完整网络请求能力
//

import Foundation
import SmartCodable

//MARK: - EmptyDecodable
/// 空模型占位：用于只需要原始响应、不走 SmartCodable 解析的请求，作为 ResponseModel 的默认类型
public struct EmptyDecodable: SmartDecodable {
    public init() {}
}

//MARK: - NetworkRequest
/// 网络请求协议
///
/// 把一个接口的全部信息（主机、路径、方法、参数、超时、重试、拦截器、外层字段映射、返回模型）
/// 都收敛到一个遵守该协议的类型里，看接口直接看这个类型。
/// 协议扩展提供了全套默认实现（默认读取 `configuration`，而 `configuration` 默认是 `NetworkConfiguration.shared`），不重写就用默认值。
///
/// 发送管道（每次尝试都会完整走一遍）：
/// 组 URL + 编码参数 → `transformRequestBody` → 请求拦截器（全局 → 自身）→ 发出
/// → 响应拦截器（全局 → 自身，可改写响应体）→ 校验 HTTP 状态码 → `transformResponseBody` → `NetworkResponse`
/// → （`send()` 时）按 `envelope` 拆壳、用 SmartCodable 解析成 `ResponseModel`
public protocol NetworkRequest {
    /// 返回模型类型（遵守 SmartDecodable，用于自动解析返回数据；同时遵守 SmartEncodable 的 SmartCodableX 也满足）
    /// 仅用 `response()` / `sendForData()` 自定义解析时可不指定，默认 EmptyDecodable
    ///
    /// 列表接口要把数组直接当返回模型（如 `[Goods]`）时，元素类型必须遵守 `SmartCodableX` 而非 `SmartDecodable`：
    /// SmartCodable 只为 `Array where Element: SmartCodableX` 提供了协议遵守，元素仅遵守 `SmartDecodable` 时数组不满足本约束。
    associatedtype ResponseModel: SmartDecodable = EmptyDecodable

    /// 本请求归属的配置（主机、默认头、拦截器、会话等都从它取）；默认 `NetworkConfiguration.shared`。多后端时为每个后端建一份配置并在这里指向它
    var configuration: NetworkConfiguration { get }
    /// 请求名字，日志与事件监听用；默认取类型名
    var name: String { get }
    /// 主机地址（含 scheme，如 "https://api.example.com"）；默认取 `configuration.baseHost`
    var host: String { get }
    /// 接口路径（如 "/user/login"）
    var path: String { get }
    /// 请求方法；默认 GET
    var method: HTTPMethod { get }
    /// 请求参数；默认无参数
    var task: RequestTask { get }
    /// 额外的 URL 查询参数；始终拼到 URL 上、可与请求体共存（适合 POST 同时带 query 与 body 的接口）。默认空
    var urlParameters: [String: Any] { get }
    /// 请求头（会叠加在配置的默认头之上）；默认空
    var headers: [String: String] { get }
    /// 超时时间（秒）；默认取 `configuration.defaultTimeout`
    var timeout: TimeInterval { get }
    /// URL 缓存策略；默认遵循协议缓存
    var cachePolicy: URLRequest.CachePolicy { get }
    /// 重试策略；默认取 `configuration.defaultRetryPolicy`
    var retryPolicy: RetryPolicy { get }
    /// 可接受的 HTTP 状态码范围，不在范围内抛 `NetworkError.httpStatus`；默认取 `configuration.defaultAcceptableStatusCodes`
    var acceptableStatusCodes: Range<Int> { get }
    /// 该请求专属的请求拦截器（在全局拦截器之后执行）；默认空
    var requestInterceptors: [RequestInterceptor] { get }
    /// 该请求专属的响应拦截器（在全局拦截器之后执行）；默认空
    var responseInterceptors: [ResponseInterceptor] { get }
    /// 对全局拦截器的启用策略；默认按 `ignoreGlobalInterceptors` 决定全开或全关
    var globalInterceptorPolicy: GlobalInterceptorPolicy { get }
    /// 是否忽略全部全局拦截器（`globalInterceptorPolicy` 的简写；特殊接口如登录 / 刷新 token 可置 true）；默认 false
    var ignoreGlobalInterceptors: Bool { get }
    /// 外层字段映射与成功判定；默认取 `configuration.defaultEnvelope`（可单请求重写成功码等）
    var envelope: ResponseEnvelope { get }
    /// 该请求专属的模型解码选项（键名策略、日期策略等）；默认取 `configuration.defaultDecodingOptions`
    var decodingOptions: Set<SmartDecodingOption> { get }
    /// 是否在后台任务保护下执行（App 切后台仍争取时间完成）；默认 true（用户何时切后台不可控，默认开启更稳）
    var runsInBackgroundTask: Bool { get }

    /// 参数编码完成后、拦截器执行前，对请求体做一次变换（典型：整体加密）。签名拦截器仍能通过 `context.originalBody` 拿到变换前的明文。默认原样返回
    func transformRequestBody(_ body: Data) throws -> Data
    /// HTTP 状态码校验通过后、拆壳解码前，对响应体做一次变换（典型：解密 / 解压）。默认原样返回
    func transformResponseBody(_ data: Data, response: HTTPURLResponse?) throws -> Data

    /// 发送请求并返回完整响应（原始数据 + HTTP 元信息 + 上下文），不做模型解析
    func response() async throws -> NetworkResponse
    /// 发送请求并按 envelope 拆壳、解析为返回模型（全程 async/await）
    func send() async throws -> ResponseModel
}

//MARK: - 默认实现
extension NetworkRequest {
    public var configuration: NetworkConfiguration { .shared }
    public var name: String { String(describing: Self.self) }
    public var host: String { configuration.baseHost }
    public var method: HTTPMethod { .get }
    public var task: RequestTask { .none }
    public var urlParameters: [String: Any] { [:] }
    public var headers: [String: String] { [:] }
    public var timeout: TimeInterval { configuration.defaultTimeout }
    public var cachePolicy: URLRequest.CachePolicy { .useProtocolCachePolicy }
    public var retryPolicy: RetryPolicy { configuration.defaultRetryPolicy }
    public var acceptableStatusCodes: Range<Int> { configuration.defaultAcceptableStatusCodes }
    public var requestInterceptors: [RequestInterceptor] { [] }
    public var responseInterceptors: [ResponseInterceptor] { [] }
    public var globalInterceptorPolicy: GlobalInterceptorPolicy { ignoreGlobalInterceptors ? .none : .all }
    public var ignoreGlobalInterceptors: Bool { false }
    public var envelope: ResponseEnvelope { configuration.defaultEnvelope }
    public var decodingOptions: Set<SmartDecodingOption> { configuration.defaultDecodingOptions }
    public var runsInBackgroundTask: Bool { true }

    /// 默认不变换请求体
    public func transformRequestBody(_ body: Data) throws -> Data { body }

    /// 默认不变换响应体
    public func transformResponseBody(_ data: Data, response: HTTPURLResponse?) throws -> Data { data }

    /// 默认实现：转交执行引擎，拿完整响应
    public func response() async throws -> NetworkResponse {
        try await NetworkClient.shared.response(for: self)
    }

    /// 默认实现：转交执行引擎，拿解析后的模型
    public func send() async throws -> ResponseModel {
        try await NetworkClient.shared.send(self)
    }
}

//MARK: - 便捷入口
extension NetworkRequest {
    /// 发送并只取原始响应体（不解析）；等价于 `response().data`
    public func sendForData() async throws -> Data {
        try await response().data
    }

    /// 旧入口：发送并返回原始数据 + HTTP 响应。请改用 `response()`，它还带耗时与上下文
    @available(*, deprecated, renamed: "response()", message: "改用 response()，NetworkResponse 同时包含 data / httpResponse / elapsed / context")
    public func sendForDataResponse() async throws -> (data: Data, response: HTTPURLResponse?) {
        let response = try await response()
        return (response.data, response.httpResponse)
    }
}
