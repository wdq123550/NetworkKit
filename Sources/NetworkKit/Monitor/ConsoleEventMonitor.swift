//
//  ConsoleEventMonitor.swift
//  NetworkKit
//
//  内置的控制台日志监听：把请求生命周期打印到 Xcode 控制台
//

import Foundation

//MARK: - ConsoleEventMonitor
/// 把请求生命周期以 `[debugLog] NetworkKit …` 风格打印到控制台。
/// `NetworkConfiguration.enableLog = true` 会在 DEBUG 下自动挂上一份；宿主也可自己加进 `eventMonitors`
public struct ConsoleEventMonitor {
    //MARK: - 存储属性
    /// 每行日志的前缀
    public var prefix: String
    /// 是否打印响应体（截断到 `bodyPreviewLimit` 字节）
    public var printsResponseBody: Bool
    /// 响应体预览的最大长度
    public var bodyPreviewLimit: Int

    /// 完整初始化
    public init(prefix: String = "[debugLog] NetworkKit", printsResponseBody: Bool = false, bodyPreviewLimit: Int = 500) {
        self.prefix = prefix
        self.printsResponseBody = printsResponseBody
        self.bodyPreviewLimit = bodyPreviewLimit
    }
}

//MARK: - 方法
extension ConsoleEventMonitor {
    /// 统一输出一行日志
    private func emit(_ message: String) {
        print("\(prefix) \(message)")
    }

    /// 把秒数格式化成两位小数
    private func format(_ interval: TimeInterval) -> String {
        String(format: "%.2fs", interval)
    }
}

//MARK: - NetworkEventMonitor
extension ConsoleEventMonitor: NetworkEventMonitor {
    public func requestWillSend(_ urlRequest: URLRequest, context: RequestContext) {
        let retry = context.isRetry ? " (第 \(context.attempt) 次重试)" : ""
        emit("➡️ [\(context.descriptor.name)] \(context.descriptor.method.rawValue) \(urlRequest.url?.absoluteString ?? "")\(retry)")
    }

    public func requestWillRetry(after error: NetworkError, delay: TimeInterval, context: RequestContext) {
        emit("🔁 [\(context.descriptor.name)] 第 \(context.attempt + 1) 次重试将在 \(format(delay)) 后进行：\(error.localizedDescription)")
    }

    public func requestDidFinish(_ result: Result<NetworkResponse, NetworkError>, context: RequestContext) {
        switch result {
        case .success(let response):
            emit("✅ [\(context.descriptor.name)] HTTP \(response.statusCode ?? 0) 耗时 \(format(response.elapsed)) 大小 \(response.data.count)B")
            if printsResponseBody, let text = response.utf8String {
                emit("📄 [\(context.descriptor.name)] \(String(text.prefix(bodyPreviewLimit)))")
            }
        case .failure(let error):
            emit("❌ [\(context.descriptor.name)] 耗时 \(format(Date().timeIntervalSince(context.startTime))) 失败：\(error.localizedDescription)")
        }
    }

    public func responseDidDecode(modelType: Any.Type, error: NetworkError?, context: RequestContext) {
        if let error {
            emit("❌ [\(context.descriptor.name)] 解析 \(modelType) 失败：\(error.localizedDescription)")
        } else {
            emit("📦 [\(context.descriptor.name)] 解析成功 \(modelType)")
        }
    }

    public func downloadDidFinish(from url: URL, result: Result<URL, NetworkError>, elapsed: TimeInterval) {
        switch result {
        case .success(let destination):
            emit("⬇️ 下载完成 \(url.absoluteString) → \(destination.lastPathComponent) 耗时 \(format(elapsed))")
        case .failure(let error):
            emit("❌ 下载失败 \(url.absoluteString)：\(error.localizedDescription)")
        }
    }
}
