//
//  MultipartFormData.swift
//  NetworkKit
//
//  multipart/form-data 请求体构造（文件 / 图片上传）
//

import Foundation

//MARK: - MultipartFormData
/// multipart/form-data 请求体：逐个 append 字段或文件，最后由框架编码成带 boundary 的二进制体
public struct MultipartFormData: Sendable {
    //MARK: - Part
    /// 表单里的一个分段（普通字段或文件）
    public struct Part: Sendable {
        /// 字段名（Content-Disposition 的 name）
        public let name: String
        /// 文件名；普通文本字段为 nil
        public let fileName: String?
        /// MIME 类型；普通文本字段为 nil
        public let mimeType: String?
        /// 分段内容
        public let data: Data

        /// 完整初始化
        public init(name: String, fileName: String? = nil, mimeType: String? = nil, data: Data) {
            self.name = name
            self.fileName = fileName
            self.mimeType = mimeType
            self.data = data
        }
    }

    //MARK: - 存储属性
    /// 分隔各分段的 boundary 字符串
    public let boundary: String
    /// 已添加的全部分段
    public private(set) var parts: [Part] = []

    /// 用指定 boundary 初始化；不传则随机生成
    public init(boundary: String = "NetworkKit.\(UUID().uuidString)") {
        self.boundary = boundary
    }
}

//MARK: - 计算属性
extension MultipartFormData {
    /// 该请求体对应的 Content-Type 请求头值
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    /// 是否还没有任何分段
    public var isEmpty: Bool { parts.isEmpty }
}

//MARK: - 方法
extension MultipartFormData {
    /// 追加一个二进制分段（文件 / 图片）
    /// - Parameters:
    ///   - data: 分段内容
    ///   - name: 字段名
    ///   - fileName: 文件名；不传则视为普通字段
    ///   - mimeType: MIME 类型，如 "image/jpeg"
    public mutating func append(_ data: Data, name: String, fileName: String? = nil, mimeType: String? = nil) {
        parts.append(Part(name: name, fileName: fileName, mimeType: mimeType, data: data))
    }

    /// 追加一个普通文本字段
    public mutating func append(_ value: String, name: String) {
        parts.append(Part(name: name, data: Data(value.utf8)))
    }

    /// 读取本地文件并作为文件分段追加
    /// - Parameters:
    ///   - fileURL: 本地文件地址
    ///   - name: 字段名
    ///   - fileName: 文件名；不传则取文件地址的最后一段
    ///   - mimeType: MIME 类型；不传则为 application/octet-stream
    public mutating func append(fileURL: URL, name: String, fileName: String? = nil, mimeType: String? = nil) throws {
        let data = try Data(contentsOf: fileURL)
        parts.append(Part(
            name: name,
            fileName: fileName ?? fileURL.lastPathComponent,
            mimeType: mimeType ?? "application/octet-stream",
            data: data
        ))
    }

    /// 把全部分段编码成符合 RFC 2388 的请求体
    public func encoded() -> Data {
        var body = Data()
        let lineBreak = "\r\n"
        for part in parts {
            body.append("--\(boundary)\(lineBreak)")
            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let fileName = part.fileName {
                disposition += "; filename=\"\(fileName)\""
            }
            body.append(disposition + lineBreak)
            if let mimeType = part.mimeType {
                body.append("Content-Type: \(mimeType)\(lineBreak)")
            }
            body.append(lineBreak)
            body.append(part.data)
            body.append(lineBreak)
        }
        body.append("--\(boundary)--\(lineBreak)")
        return body
    }
}

//MARK: - Data 追加字符串
private extension Data {
    /// 把字符串按 UTF-8 追加到数据末尾
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
