//
//  HTTPMethod.swift
//  NetworkKit
//
//  HTTP 请求方法
//

import Foundation

//MARK: - 枚举定义
/// HTTP 请求方法
public enum HTTPMethod: String, Sendable {
    /// 查询：参数默认拼到 URL query 上
    case get = "GET"
    /// 提交：参数默认放到请求体
    case post = "POST"
    /// 全量更新
    case put = "PUT"
    /// 删除
    case delete = "DELETE"
    /// 局部更新
    case patch = "PATCH"
    /// 仅获取响应头
    case head = "HEAD"
    /// 预检 / 能力探测
    case options = "OPTIONS"
}

//MARK: - 计算属性
extension HTTPMethod {
    /// 该方法默认是否把参数编码到请求体（GET / HEAD / OPTIONS 走 query，其余走 body）
    public var prefersBodyEncoding: Bool {
        switch self {
        case .get, .head, .options: return false
        default: return true
        }
    }
}
