//
//  RetryPolicy.swift
//  NetworkKit
//
//  请求重试策略：次数、退避间隔、判定条件
//

import Foundation

//MARK: - 枚举定义
/// 重试间隔的退避方式
public enum RetryDelay: Sendable {
    /// 不等待，立即重试
    case none
    /// 固定间隔（秒）
    case constant(TimeInterval)
    /// 指数退避：第 n 次重试等待 `initial * multiplier^(n-1)`，不超过 `maximum`，再叠加 `jitter` 比例的随机抖动（0~1）
    case exponential(initial: TimeInterval, multiplier: Double = 2, maximum: TimeInterval = 30, jitter: Double = 0)

    /// 计算第 n 次重试（n 从 1 开始）前应等待的秒数
    public func interval(forRetry retryIndex: Int) -> TimeInterval {
        switch self {
        case .none:
            return 0
        case .constant(let interval):
            return max(0, interval)
        case .exponential(let initial, let multiplier, let maximum, let jitter):
            let exponent = Double(max(0, retryIndex - 1))
            let base = min(maximum, initial * pow(multiplier, exponent))
            guard jitter > 0 else { return base }
            let spread = base * min(1, jitter)
            return max(0, base + Double.random(in: -spread...spread))
        }
    }
}

//MARK: - RetryPolicy
/// 请求重试策略
public struct RetryPolicy: Sendable {
    //MARK: - 存储属性
    /// 最大重试次数（不含首次请求；0 表示不重试）
    public var maxRetryCount: Int
    /// 每次重试前的退避方式
    public var delay: RetryDelay
    /// 重试时是否重新走一遍组包（重新编码参数、重跑 `transformRequestBody` 与拦截器）。默认 true，保证签名里的时间戳等每次都是新的
    public var rebuildsRequestOnRetry: Bool
    /// 自定义是否重试：入参为本次错误与「已重试次数」，返回 true 表示继续重试。取消永不重试
    public var shouldRetry: @Sendable (_ error: NetworkError, _ retriedCount: Int) -> Bool

    /// 完整初始化
    /// - Parameters:
    ///   - maxRetryCount: 最大重试次数
    ///   - delay: 退避方式，默认不等待
    ///   - rebuildsRequestOnRetry: 重试时是否重新组包，默认 true
    ///   - shouldRetry: 自定义判定；默认仅对「网络传输类错误 / 超时」重试，业务错误不重试
    public init(
        maxRetryCount: Int = 0,
        delay: RetryDelay = .none,
        rebuildsRequestOnRetry: Bool = true,
        shouldRetry: @escaping @Sendable (_ error: NetworkError, _ retriedCount: Int) -> Bool = { RetryPolicy.defaultShouldRetry($0, $1) }
    ) {
        self.maxRetryCount = maxRetryCount
        self.delay = delay
        self.rebuildsRequestOnRetry = rebuildsRequestOnRetry
        self.shouldRetry = shouldRetry
    }

    /// 便捷初始化：固定间隔重试
    /// - Parameters:
    ///   - maxRetryCount: 最大重试次数
    ///   - retryDelay: 固定间隔（秒）
    ///   - shouldRetry: 自定义判定，默认仅对传输错误 / 超时重试
    public init(
        maxRetryCount: Int,
        retryDelay: TimeInterval,
        shouldRetry: @escaping @Sendable (_ error: NetworkError, _ retriedCount: Int) -> Bool = { RetryPolicy.defaultShouldRetry($0, $1) }
    ) {
        self.init(maxRetryCount: maxRetryCount, delay: .constant(retryDelay), shouldRetry: shouldRetry)
    }

    /// 不重试（全局默认）
    public static let none = RetryPolicy(maxRetryCount: 0)
}

//MARK: - 方法
extension RetryPolicy {
    /// 默认重试判定：仅对底层传输错误与超时重试，业务错误不重试
    public static func defaultShouldRetry(_ error: NetworkError, _ retriedCount: Int) -> Bool {
        switch error {
        case .transport, .timeout: return true
        default: return false
        }
    }

    /// 更宽的判定：传输错误、超时，以及 408 / 429 / 5xx 这类服务端瞬时故障都重试（业务错误仍不重试）
    public static func transientShouldRetry(_ error: NetworkError, _ retriedCount: Int) -> Bool {
        switch error {
        case .transport, .timeout:
            return true
        case .httpStatus(let code, _):
            return code == 408 || code == 429 || (500..<600).contains(code)
        default:
            return false
        }
    }
}
