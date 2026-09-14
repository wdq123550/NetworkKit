//
//  HMACSignatureInterceptor.swift
//  NetworkKit
//
//  通用 HMAC 签名拦截器：按「方法 + 路径 + query + 请求体」等材料计算 HMAC 并写入请求头
//

import Foundation

//MARK: - HMACSignatureInterceptor
/// 通用 HMAC 签名拦截器
///
/// 默认签名材料为 `"\(METHOD)\n\(path)\n\(query)\n\(body)"`，HMAC-SHA256，Base64 URL-safe 输出，写入 `X-Signature`——
/// 这是公司 go-cloud / func / 配置中心 / 审核等网关的共同口径；别的网关通过 `material` 闭包自定义拼接方式即可。
/// 请求体默认取 `context.originalBody`（加密前的明文），所以与 `transformRequestBody` 里的 DES 加密天然配合。
public struct HMACSignatureInterceptor {
    //MARK: - 枚举定义
    /// 参与签名的请求体来源
    public enum BodySource: Sendable {
        /// 参数编码后、任何改写之前的原始请求体（默认；「签明文、发密文」用这个）
        case originalBody
        /// 拦截器执行时 URLRequest 上的当前请求体（前面的拦截器已改写过就用改写后的）
        case currentBody
        /// 不带请求体（材料里的 body 段为空串）
        case none
    }
    /// 签名结果的输出编码
    public enum OutputEncoding: Sendable {
        /// Base64 URL-safe（`+`→`-`、`/`→`_`、去掉 `=`）
        case base64URLSafe
        /// 标准 Base64
        case base64
        /// 小写十六进制
        case hex
    }

    //MARK: - 存储属性
    /// 写入签名的请求头名
    public var headerName: String
    /// 签名密钥
    public var secret: String
    /// HMAC 摘要算法
    public var algorithm: Algorithm
    /// 参与签名的请求体来源
    public var bodySource: BodySource
    /// 签名结果的输出编码
    public var outputEncoding: OutputEncoding
    /// 把请求与请求体字符串拼成待签名材料的闭包
    public var material: @Sendable (_ request: URLRequest, _ body: String) -> String

    /// 完整初始化
    /// - Parameters:
    ///   - headerName: 写入签名的请求头名，默认 `X-Signature`
    ///   - secret: 签名密钥
    ///   - algorithm: HMAC 摘要算法，默认 SHA256
    ///   - bodySource: 参与签名的请求体来源，默认原始请求体
    ///   - outputEncoding: 输出编码，默认 Base64 URL-safe
    ///   - material: 待签名材料的拼接方式，默认 `方法\n路径\nquery\n请求体`
    public init(
        headerName: String = "X-Signature",
        secret: String,
        algorithm: Algorithm = .sha256,
        bodySource: BodySource = .originalBody,
        outputEncoding: OutputEncoding = .base64URLSafe,
        material: @escaping @Sendable (_ request: URLRequest, _ body: String) -> String = { HMACSignatureInterceptor.methodPathQueryBody($0, $1) }
    ) {
        self.headerName = headerName
        self.secret = secret
        self.algorithm = algorithm
        self.bodySource = bodySource
        self.outputEncoding = outputEncoding
        self.material = material
    }
}

//MARK: - 方法
extension HMACSignatureInterceptor {
    /// 默认材料拼接：`"\(METHOD)\n\(path)\n\(query)\n\(body)"`
    public static func methodPathQueryBody(_ request: URLRequest, _ body: String) -> String {
        let method = request.httpMethod ?? "POST"
        let path = request.url?.path ?? ""
        let query = request.url?.query ?? ""
        return "\(method)\n\(path)\n\(query)\n\(body)"
    }

    /// 对给定材料计算 HMAC 并按输出编码转成字符串
    public func signature(for material: String) -> String {
        let digest = Data(material.utf8).digest(algorithm, key: secret)
        switch outputEncoding {
        case .base64URLSafe: return EncryptHelper.encodeBase64URLSafeString(data: digest) ?? ""
        case .base64: return digest.base64EncodedString()
        case .hex: return digest.map { String(format: "%02x", $0) }.joined()
        }
    }
}

//MARK: - RequestInterceptor
extension HMACSignatureInterceptor: RequestInterceptor {
    /// 按配置取请求体、拼材料、算签名并写入请求头
    public func intercept(_ request: inout URLRequest, context: RequestContext) async throws {
        let body: String
        switch bodySource {
        case .originalBody: body = context.originalBodyString ?? ""
        case .currentBody: body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        case .none: body = ""
        }
        request.setValue(signature(for: material(request, body)), forHTTPHeaderField: headerName)
    }
}
