//
//  NetworkEventMonitor.swift
//  NetworkKit
//
//  请求生命周期事件监听：统一日志 / 埋点 / 耗时统计的唯一出口
//

import Foundation

//MARK: - NetworkEventMonitor
/// 请求生命周期事件监听。所有方法都有空默认实现，只实现关心的即可。
/// 宿主 App 用它接自己的日志系统，业务侧就不必再在每个请求外面手写「发起 / 成功耗时 / 失败原因」
public protocol NetworkEventMonitor: Sendable {
    /// 请求即将发出（每次尝试都会回调，含重试）
    func requestWillSend(_ urlRequest: URLRequest, context: RequestContext)

    /// 本次尝试失败、即将在 delay 秒后重试
    func requestWillRetry(after error: NetworkError, delay: TimeInterval, context: RequestContext)

    /// 请求最终结束（成功拿到响应，或用尽重试后失败）；不含模型解析阶段
    func requestDidFinish(_ result: Result<NetworkResponse, NetworkError>, context: RequestContext)

    /// `send()` 的模型解析阶段结束；`error` 为 nil 表示解析成功
    func responseDidDecode(modelType: Any.Type, error: NetworkError?, context: RequestContext)

    /// 文件下载结束
    func downloadDidFinish(from url: URL, result: Result<URL, NetworkError>, elapsed: TimeInterval)
}

//MARK: - 默认实现
extension NetworkEventMonitor {
    public func requestWillSend(_ urlRequest: URLRequest, context: RequestContext) {}
    public func requestWillRetry(after error: NetworkError, delay: TimeInterval, context: RequestContext) {}
    public func requestDidFinish(_ result: Result<NetworkResponse, NetworkError>, context: RequestContext) {}
    public func responseDidDecode(modelType: Any.Type, error: NetworkError?, context: RequestContext) {}
    public func downloadDidFinish(from url: URL, result: Result<URL, NetworkError>, elapsed: TimeInterval) {}
}

//MARK: - 数组转发
extension Array where Element == NetworkEventMonitor {
    /// 把事件依次转发给每个监听者
    func requestWillSend(_ urlRequest: URLRequest, context: RequestContext) {
        forEach { $0.requestWillSend(urlRequest, context: context) }
    }

    func requestWillRetry(after error: NetworkError, delay: TimeInterval, context: RequestContext) {
        forEach { $0.requestWillRetry(after: error, delay: delay, context: context) }
    }

    func requestDidFinish(_ result: Result<NetworkResponse, NetworkError>, context: RequestContext) {
        forEach { $0.requestDidFinish(result, context: context) }
    }

    func responseDidDecode(modelType: Any.Type, error: NetworkError?, context: RequestContext) {
        forEach { $0.responseDidDecode(modelType: modelType, error: error, context: context) }
    }

    func downloadDidFinish(from url: URL, result: Result<URL, NetworkError>, elapsed: TimeInterval) {
        forEach { $0.downloadDidFinish(from: url, result: result, elapsed: elapsed) }
    }
}
