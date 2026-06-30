//
//  EncryptHelper.swift
//  NetworkKit
//
//  请求加密 / 签名辅助：DES 请求体加密、HMAC-SHA256 签名、Base64 URL-safe 编码
//

import Foundation

public enum EncryptHelper {
    /// 加密请求体：明文 Data 经 DES 加密后转成 base64 字符串
    public static func encodeRequestBody(data: Data, desKey: String) -> String? {
        guard let keyData = desKey.data(using: String.Encoding.utf8) else {
            return nil
        }

        var data = data
        let result = data.enCrypt(algorithm: CryptoAlgorithm.DES, keyData: keyData)
        let base64Str = result?.base64EncodedString(options: .init(rawValue: 0))

        return base64Str
    }

    /// 按「请求方法 + path + query + body」计算 HMAC-SHA256 签名（Base64 URL-safe）
    public static func getSignature(request: URLRequest, requestBody payload: String, signatureKey: String) -> String {
        let httpMethod = request.httpMethod ?? "POST"
        let path = request.url?.path ?? ""
        let query = request.url?.query ?? ""

        let valueToDigest = "\(httpMethod)\n\(path)\n\(query)\n\(payload)"
        let signature = createSignature(signatureKey: signatureKey, valueToDigest: valueToDigest)
        return signature ?? ""
    }

    /// 把 Data 编码成 Base64 URL-safe 字符串（+→-、/→_、去掉补位 =）
    public static func encodeBase64URLSafeString(data: Data) -> String? {
        var base64Str = data.base64EncodedString(options: .lineLength64Characters)
        base64Str = base64Str.replacingOccurrences(of: "+", with: "-")
        base64Str = base64Str.replacingOccurrences(of: "/", with: "_")
        base64Str = base64Str.replacingOccurrences(of: "=", with: "")
        return base64Str
    }

    /// Base64 URL-safe 字符串解码（与 `encodeBase64URLSafeString` 互逆，补回 = 与 +/）
    public static func decodeBase64URLSafeString(_ base64String: String) -> Data? {
        var base64 = base64String
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        return Data(base64Encoded: base64)
    }

    /// DES 加密为二进制密文（密钥为 URL-safe Base64 编码，与 encodeRequestBody 的 UTF-8 明文 key 不同）
    public static func encryptDESBinary(data: Data, base64DESKey: String) -> Data? {
        guard let keyData = decodeBase64URLSafeString(base64DESKey) else { return nil }
        var mutableData = data
        return mutableData.enCrypt(algorithm: .DES, keyData: keyData)
    }

    /// DES 解密二进制密文（密钥为 URL-safe Base64 编码）
    public static func decryptDESBinary(data: Data, base64DESKey: String) -> Data? {
        guard let keyData = decodeBase64URLSafeString(base64DESKey) else { return nil }
        var mutableData = data
        return mutableData.deCrypt(algorithm: .DES, keyData: keyData)
    }

    private static func createSignature(signatureKey: String, valueToDigest: String) -> String? {
        let data = valueToDigest.data(using: String.Encoding.utf8)
        if let data = data {
            let hmac = data.digest(.sha256, key: signatureKey)
            let signature = encodeBase64URLSafeString(data: hmac)
            return signature
        }
        return ""
    }
}
