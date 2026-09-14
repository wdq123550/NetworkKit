//
//  RequestTask.swift
//  NetworkKit
//
//  请求参数的承载方式（Codable 结构体 / 松散字典 / 表单 / multipart / 原始数据）
//

import Foundation

//MARK: - 枚举定义
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
    /// 松散字典参数 → 编码成 `application/x-www-form-urlencoded` 表单请求体
    case formParameters([String: Any])
    /// multipart/form-data 请求体（文件上传）；Content-Type 由框架按 boundary 自动填写
    case multipart(MultipartFormData)
    /// 直接发送的原始请求体数据（自定义编码场景兜底）；可顺带指定 Content-Type，不传则沿用默认请求头
    case rawBody(Data, contentType: String? = nil)
}

//MARK: - 计算属性
extension RequestTask {
    /// 该承载方式是否属于「请求体」类参数（query 类与无参数返回 false）
    var carriesBody: Bool {
        switch self {
        case .none, .query, .queryParameters: return false
        case .jsonBody, .jsonParameters, .formParameters, .multipart, .rawBody: return true
        }
    }
}

//MARK: - AnyEncodable
/// Encodable 的类型擦除包装，便于把任意 Codable 结构体塞进 enum 关联值后再统一编码
public struct AnyEncodable {
    /// 真正执行编码的闭包（捕获原始值的具体类型）
    private let encodeClosure: (Encoder) throws -> Void

    /// 用任意 Encodable 值初始化
    public init(_ wrapped: Encodable) {
        self.encodeClosure = wrapped.encode
    }
}

//MARK: - Encodable
extension AnyEncodable: Encodable {
    /// 把被包装的值原样编码进给定的 Encoder
    public func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}
