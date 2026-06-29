//
//  GoCloudSignatureInterceptor.swift
//  NetworkKit
//
//  go-cloud 网关签名请求拦截器
//

import Foundation

// MARK: - GoCloud 签名拦截器
/// 按「请求方法 + path + query + body」计算 HMAC-SHA256 签名，写入 X-Signature 请求头
/// 适配 go-cloud / func 等同款签名网关，签名密钥按服务传入
public struct GoCloudSignatureInterceptor: RequestInterceptor {
    /// 签名密钥（不同后端服务对应不同 secret）
    public let signatureKey: String

    public init(signatureKey: String) {
        self.signatureKey = signatureKey
    }
}

// MARK: - RequestInterceptor
public extension GoCloudSignatureInterceptor {
    func intercept(_ request: inout URLRequest) async throws {
        // 取出已编码好的请求体字符串（GET 等无 body 时为空串，与旧实现一致）
        let bodyString = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let signature = EncryptHelper.getSignature(request: request, requestBody: bodyString, signatureKey: signatureKey)
        request.setValue(signature, forHTTPHeaderField: "X-Signature")
    }
}
