//
//  Interceptors.swift
//  NetworkKit
//
//  请求 / 返回拦截器协议
//

import Foundation

// MARK: - RequestInterceptor
/// 请求发出前的拦截器：可改 header、加签名、加 token 等
public protocol RequestInterceptor {
    /// 在请求发出前修改 URLRequest（async 以支持异步取 token 等场景）
    /// - Parameter request: 即将发出的请求，可原地修改
    func intercept(_ request: inout URLRequest) async throws
}

// MARK: - ResponseInterceptor
/// 收到返回后的拦截器：可做统一日志、登录失效跳转、解密、埋点等
public protocol ResponseInterceptor {
    /// 在数据解析前介入原始返回
    /// - Parameters:
    ///   - data: 原始返回体
    ///   - response: URL 响应
    ///   - request: 本次请求（便于上下文判断）
    func intercept(data: Data, response: URLResponse, for request: URLRequest) async throws
}
