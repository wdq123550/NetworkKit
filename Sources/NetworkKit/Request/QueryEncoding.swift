//
//  QueryEncoding.swift
//  NetworkKit
//
//  URL query / 表单参数的编码规则与实现
//

import Foundation

//MARK: - QueryEncodingOptions
/// URL query 与表单参数的编码选项
public struct QueryEncodingOptions: Sendable {
    //MARK: - 枚举定义
    /// 数组参数的编码方式
    public enum ArrayEncoding: Sendable {
        /// 重复键名：`ids=1&ids=2`
        case repeatKey
        /// 键名加方括号：`ids[]=1&ids[]=2`
        case brackets
        /// 键名加下标：`ids[0]=1&ids[1]=2`
        case indexed
        /// 逗号拼接：`ids=1,2`
        case commaSeparated
    }
    /// 布尔参数的编码方式
    public enum BoolEncoding: Sendable {
        /// 字面量：`true` / `false`
        case literal
        /// 数字：`1` / `0`
        case numeric
    }

    //MARK: - 存储属性
    /// 数组参数的编码方式，默认重复键名
    public var arrayEncoding: ArrayEncoding = .repeatKey
    /// 布尔参数的编码方式，默认字面量
    public var boolEncoding: BoolEncoding = .literal
    /// 是否把值里的 `+` 转义成 `%2B`（URLComponents 默认不转，部分服务端会把 `+` 当空格），默认开
    public var encodesPlusSign: Bool = true
    /// 是否按键名排序（便于日志比对与签名稳定），默认开
    public var sortsKeys: Bool = true

    /// 全部使用默认值初始化
    public init() {}
}

//MARK: - QueryEncoder
/// 把松散字典 / Encodable 结构体编码成 URL 查询项或表单请求体
enum QueryEncoder {
    /// 把松散字典展开成 URL 查询项（嵌套字典按 `key[sub]` 展开，数组按 options 编码）
    static func queryItems(from dictionary: [String: Any], options: QueryEncodingOptions) -> [URLQueryItem] {
        let keys = options.sortsKeys ? dictionary.keys.sorted() : Array(dictionary.keys)
        return keys.flatMap { key in
            queryItems(key: key, value: dictionary[key], options: options)
        }
    }

    /// 把 Encodable 结构体编码成 URL 查询项（先经 JSON 中转，再按字典规则展开）
    static func queryItems(from encodable: Encodable, encoder: JSONEncoder, options: QueryEncodingOptions) throws -> [URLQueryItem] {
        let data: Data
        do {
            data = try encoder.encode(AnyEncodable(encodable))
        } catch {
            throw NetworkError.encoding(error)
        }
        guard let dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        return queryItems(from: dictionary, options: options)
    }

    /// 把查询项拼成 `application/x-www-form-urlencoded` 表单请求体
    static func formBody(from items: [URLQueryItem], options: QueryEncodingOptions) -> Data {
        var components = URLComponents()
        components.queryItems = items
        let query = percentEncodedQuery(of: components, options: options) ?? ""
        return Data(query.utf8)
    }

    /// 取出 URLComponents 的百分号编码 query，并按选项补转 `+`
    static func percentEncodedQuery(of components: URLComponents, options: QueryEncodingOptions) -> String? {
        guard let query = components.percentEncodedQuery else { return nil }
        guard options.encodesPlusSign else { return query }
        return query.replacingOccurrences(of: "+", with: "%2B")
    }

    /// 把单个键值展开成一个或多个查询项
    private static func queryItems(key: String, value: Any?, options: QueryEncodingOptions) -> [URLQueryItem] {
        switch value {
        case .none:
            return []
        case let nested as [String: Any]:
            let nestedKeys = options.sortsKeys ? nested.keys.sorted() : Array(nested.keys)
            return nestedKeys.flatMap { subKey in
                queryItems(key: "\(key)[\(subKey)]", value: nested[subKey], options: options)
            }
        case let array as [Any]:
            switch options.arrayEncoding {
            case .repeatKey:
                return array.flatMap { queryItems(key: key, value: $0, options: options) }
            case .brackets:
                return array.flatMap { queryItems(key: "\(key)[]", value: $0, options: options) }
            case .indexed:
                return array.enumerated().flatMap { index, element in
                    queryItems(key: "\(key)[\(index)]", value: element, options: options)
                }
            case .commaSeparated:
                let joined = array.compactMap { scalarString($0, options: options) }.joined(separator: ",")
                return [URLQueryItem(name: key, value: joined)]
            }
        default:
            guard let string = scalarString(value, options: options) else { return [] }
            return [URLQueryItem(name: key, value: string)]
        }
    }

    /// 把标量值转成查询字符串（区分 Bool 与数字，避免 true 变成 1）
    private static func scalarString(_ value: Any?, options: QueryEncodingOptions) -> String? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let bool = value as? Bool, isBoolean(value) {
            switch options.boolEncoding {
            case .literal: return bool ? "true" : "false"
            case .numeric: return bool ? "1" : "0"
            }
        }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return "\(value)"
    }

    /// 判断一个值是否真的是布尔（Swift Bool 或 JSON 里的 CFBoolean），排除 NSNumber 0/1 被误判
    private static func isBoolean(_ value: Any) -> Bool {
        if type(of: value) == Bool.self { return true }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        return false
    }
}
