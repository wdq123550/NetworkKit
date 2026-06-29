//
//  RetryPolicy.swift
//  NetworkKit
//
//  请求重试策略
//

import Foundation

// MARK: - RetryPolicy
/// 请求重试策略
public struct RetryPolicy {
    /// 最大重试次数（不含首次请求；0 表示不重试）
    public var maxRetryCount: Int
    /// 每次重试前的等待间隔（秒）
    public var retryDelay: TimeInterval
    /// 自定义是否重试：入参为本次错误与「已重试次数」，返回 true 表示继续重试
    public var shouldRetry: (_ error: Error, _ retriedCount: Int) -> Bool

    /// 完整初始化
    /// - Parameters:
    ///   - maxRetryCount: 最大重试次数
    ///   - retryDelay: 重试间隔（秒）
    ///   - shouldRetry: 自定义判定；默认仅对「网络传输类错误」重试，业务错误不重试
    public init(
        maxRetryCount: Int = 0,
        retryDelay: TimeInterval = 0,
        shouldRetry: @escaping (_ error: Error, _ retriedCount: Int) -> Bool = RetryPolicy.defaultShouldRetry
    ) {
        self.maxRetryCount = maxRetryCount
        self.retryDelay = retryDelay
        self.shouldRetry = shouldRetry
    }

    /// 不重试（全局默认）
    public static let none = RetryPolicy(maxRetryCount: 0)

    /// 默认重试判定：仅对底层传输错误与超时重试，业务错误不重试
    public static func defaultShouldRetry(_ error: Error, _ retriedCount: Int) -> Bool {
        switch error {
        case NetworkError.transport, NetworkError.timeout:
            return true
        default:
            return false
        }
    }
}
