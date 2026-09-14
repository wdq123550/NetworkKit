//
//  RequestContext.swift
//  NetworkKit
//
//  请求进入发送管道后的描述与上下文：拦截器、事件监听不持有原始请求对象也能知道「这是哪个接口、第几次尝试、原始请求体是什么」
//

import Foundation

//MARK: - RequestDescriptor
/// 一次请求的静态描述（不含参数明细），用于日志、埋点与拦截器识别接口
public struct RequestDescriptor: Sendable {
    /// 本次发送的唯一标识；同一个请求对象每次调用 send 都会生成新的标识
    public let id: UUID
    /// 请求的名字，默认取遵守 NetworkRequest 的类型名，日志里用它区分接口
    public let name: String
    /// 主机地址（含 scheme）
    public let host: String
    /// 接口路径
    public let path: String
    /// HTTP 方法
    public let method: HTTPMethod
    /// 超时时间（秒）
    public let timeout: TimeInterval

    /// 完整初始化
    public init(id: UUID = UUID(), name: String, host: String, path: String, method: HTTPMethod, timeout: TimeInterval) {
        self.id = id
        self.name = name
        self.host = host
        self.path = path
        self.method = method
        self.timeout = timeout
    }
}

//MARK: - 计算属性
extension RequestDescriptor {
    /// 主机与路径拼成的完整地址（不含 query），日志用
    public var url: String { host + path }
}

//MARK: - RequestContext
/// 请求在发送管道内一路传递的上下文，请求拦截器、响应拦截器与事件监听都能拿到它
public struct RequestContext: Sendable {
    /// 本次请求的静态描述
    public let descriptor: RequestDescriptor
    /// 参数编码完成后、`transformRequestBody` 与任何拦截器改写之前的原始请求体；签名类拦截器应以它为准而不是读 `URLRequest.httpBody`
    public let originalBody: Data?
    /// 当前是第几次尝试：0 表示首发，重试一次则为 1
    public let attempt: Int
    /// 本次发送（含全部重试）的起始时间
    public let startTime: Date

    /// 完整初始化
    public init(descriptor: RequestDescriptor, originalBody: Data?, attempt: Int, startTime: Date) {
        self.descriptor = descriptor
        self.originalBody = originalBody
        self.attempt = attempt
        self.startTime = startTime
    }
}

//MARK: - 计算属性
extension RequestContext {
    /// 当前是否为重试（attempt > 0）
    public var isRetry: Bool { attempt > 0 }
    /// 原始请求体按 UTF-8 解成的字符串；请求体不是文本时为 nil
    public var originalBodyString: String? {
        originalBody.flatMap { String(data: $0, encoding: .utf8) }
    }
}
