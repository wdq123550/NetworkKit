//
//  NetworkRequest.swift
//  NetworkKit
//
//  核心请求协议：一个对象遵守它即拥有完整网络请求能力
//

import Foundation
import SmartCodable

// MARK: - NetworkRequest
/// 网络请求协议
///
/// 把一个接口的全部信息（主机、路径、方法、参数、超时、重试、拦截器、外层字段映射、返回模型）
/// 都收敛到一个遵守该协议的类型里，看接口直接看这个类型。
/// 协议扩展提供了全套默认实现（默认读取 `NetworkConfiguration.shared`），不重写就用默认值。
public protocol NetworkRequest {
    /// 返回模型类型（遵守 SmartDecodable，用于自动解析返回数据；同时遵守 SmartEncodable 的 SmartCodableX 也满足）
    associatedtype ResponseModel: SmartDecodable

    /// 主机地址（含 scheme，如 "https://api.example.com"）；默认取全局配置
    var host: String { get }
    /// 接口路径（如 "/user/login"）
    var path: String { get }
    /// 请求方法；默认 GET
    var method: HTTPMethod { get }
    /// 请求参数；默认无参数
    var task: RequestTask { get }
    /// 额外的 URL 查询参数；始终拼到 URL 上、可与请求体共存（适合 POST 同时带 query 与 body 的接口）。默认空
    var urlParameters: [String: Any] { get }
    /// 请求头（会叠加在全局默认头之上）；默认空
    var headers: [String: String] { get }
    /// 超时时间（秒）；默认取全局配置
    var timeout: TimeInterval { get }
    /// 重试策略；默认取全局配置
    var retryPolicy: RetryPolicy { get }
    /// 该请求专属的请求拦截器；默认空
    var requestInterceptors: [RequestInterceptor] { get }
    /// 该请求专属的返回拦截器；默认空
    var responseInterceptors: [ResponseInterceptor] { get }
    /// 外层字段映射与成功判定；默认取全局配置（可单请求重写成功码等）
    var envelope: ResponseEnvelope { get }
    /// URL 缓存策略；默认遵循协议缓存
    var cachePolicy: URLRequest.CachePolicy { get }
    /// 是否忽略全局拦截器（特殊接口如登录/刷新 token 可置 true）；默认 false
    var ignoreGlobalInterceptors: Bool { get }
    /// 是否在后台任务保护下执行（App 切后台仍争取时间完成）；默认 true（用户何时切后台不可控，默认开启更稳）
    var runsInBackgroundTask: Bool { get }

    /// 发送请求并解析为返回模型（全程 async/await）
    func send() async throws -> ResponseModel
}

// MARK: - 默认实现
extension NetworkRequest {
    public var host: String { NetworkConfiguration.shared.baseHost }
    public var method: HTTPMethod { .get }
    public var task: RequestTask { .none }
    public var urlParameters: [String: Any] { [:] }
    public var headers: [String: String] { [:] }
    public var timeout: TimeInterval { NetworkConfiguration.shared.defaultTimeout }
    public var retryPolicy: RetryPolicy { NetworkConfiguration.shared.defaultRetryPolicy }
    public var requestInterceptors: [RequestInterceptor] { [] }
    public var responseInterceptors: [ResponseInterceptor] { [] }
    public var envelope: ResponseEnvelope { NetworkConfiguration.shared.defaultEnvelope }
    public var cachePolicy: URLRequest.CachePolicy { .useProtocolCachePolicy }
    public var ignoreGlobalInterceptors: Bool { false }
    public var runsInBackgroundTask: Bool { true }

    /// 默认发送实现：转交执行引擎
    public func send() async throws -> ResponseModel {
        try await NetworkClient.shared.send(self)
    }
}
