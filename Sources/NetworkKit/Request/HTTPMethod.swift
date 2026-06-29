//
//  HTTPMethod.swift
//  NetworkKit
//
//  HTTP 请求方法
//

import Foundation

// MARK: - 枚举定义
/// HTTP 请求方法
public enum HTTPMethod: String {
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

    /// 该方法默认是否把参数编码到请求体（GET/HEAD 走 query，其余走 body）
    public var prefersBodyEncoding: Bool {
        switch self {
        case .get, .head: return false
        default: return true
        }
    }
}
