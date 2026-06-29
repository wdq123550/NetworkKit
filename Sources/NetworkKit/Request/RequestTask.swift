//
//  RequestTask.swift
//  NetworkKit
//
//  请求参数的承载方式（Codable 结构体或松散字典自动编码）
//

import Foundation

// MARK: - 枚举定义
/// 请求参数的承载方式
public enum RequestTask {
    /// 无参数
    case none
    /// 结构体参数 → 拼到 URL query 上（任意 Encodable）
    case query(Encodable)
    /// 结构体参数 → 编码成 JSON 请求体（任意 Encodable）
    case jsonBody(Encodable)
    /// 松散字典参数 → 拼到 URL query 上（无需定义结构体的简单场景）
    case queryParameters([String: Any])
    /// 松散字典参数 → 编码成 JSON 请求体（无需定义结构体的简单场景）
    case jsonParameters([String: Any])
    /// 直接发送的原始请求体数据（自定义编码场景兜底）
    case rawBody(Data)
}

// MARK: - AnyEncodable
/// Encodable 的类型擦除包装，便于把任意 Codable 结构体塞进 enum 关联值后再统一编码
public struct AnyEncodable: Encodable {
    /// 真正执行编码的闭包（捕获原始值的具体类型）
    private let encodeClosure: (Encoder) throws -> Void

    /// 用任意 Encodable 值初始化
    public init(_ wrapped: Encodable) {
        self.encodeClosure = wrapped.encode
    }

    public func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}
