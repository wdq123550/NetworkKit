//
//  NetworkConfiguration.swift
//  NetworkKit
//
//  全局网络配置（默认主机、超时、拦截器、外层字段映射等）
//

import Foundation
import Observation

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
    /// 默认重试策略
    public var defaultRetryPolicy: RetryPolicy = .none
    /// 全局请求拦截器（对所有未忽略全局拦截器的请求生效，先于请求自身拦截器执行）
    @ObservationIgnored public var globalRequestInterceptors: [RequestInterceptor] = []
    /// 全局返回拦截器（先于请求自身拦截器执行）
    @ObservationIgnored public var globalResponseInterceptors: [ResponseInterceptor] = []
    /// 是否打印调试日志（沿用项目 [debugLog] 风格）
    public var enableLog: Bool = false
    /// 底层会话（默认用 .default 配置，可整体替换）
    @ObservationIgnored public var session: URLSession = .shared
}
