//
//  Interceptors.swift
//  NetworkKit
//
//  请求 / 响应拦截器协议，以及全局拦截器的启用策略
//

import Foundation

//MARK: - RequestInterceptor
/// 请求发出前的拦截器：可改 header、加签名、加 token、替换请求体等
///
/// 上下文里的 `originalBody` 是参数编码后、任何改写之前的原始请求体。
/// 「签明文、发密文」这类需求，签名拦截器读 `context.originalBody`，加密放在 `transformRequestBody` 或另一个拦截器里，二者互不干扰。
public protocol RequestInterceptor: Sendable {
    /// 在请求发出前修改 URLRequest（async 以支持异步取 token 等场景）
    /// - Parameters:
    ///   - request: 即将发出的请求，可原地修改
    ///   - context: 请求上下文（描述、原始请求体、第几次尝试）
    func intercept(_ request: inout URLRequest, context: RequestContext) async throws
}

//MARK: - ResponseInterceptor
/// 收到返回后的拦截器：可做统一日志、登录失效处理、解密解压（直接改 `response.data`）等
///
/// 它跑在 HTTP 状态码校验**之前**，所以能看到 401 / 500 这类响应；
/// 只想对成功响应做解密 / 解压时，用 `NetworkRequest.transformResponseBody` 更直接。
public protocol ResponseInterceptor: Sendable {
    /// 在状态码校验与模型解析前介入响应，可原地改写响应体
    /// - Parameter response: 本次响应（含原始数据、HTTP 元信息与请求上下文）
    func intercept(_ response: inout NetworkResponse) async throws
}

//MARK: - 枚举定义
/// 单个请求对全局拦截器的启用策略
public enum GlobalInterceptorPolicy: Sendable {
    /// 全部启用（默认）
    case all
    /// 全部跳过（登录、刷新 token、第三方独立服务等）
    case none
    /// 只跳过指定类型的全局拦截器
    case excluding([ObjectIdentifier])

    /// 便捷构造：按类型排除，如 `.excluding(AuthInterceptor.self, LoggingInterceptor.self)`
    public static func excluding(_ types: Any.Type...) -> GlobalInterceptorPolicy {
        .excluding(types.map(ObjectIdentifier.init))
    }
}

//MARK: - 方法
extension GlobalInterceptorPolicy {
    /// 判断某个全局拦截器实例在本策略下是否应该执行
    func allows(_ interceptor: Any) -> Bool {
        switch self {
        case .all: return true
        case .none: return false
        case .excluding(let excluded): return excluded.contains(ObjectIdentifier(type(of: interceptor))) == false
        }
    }
}
