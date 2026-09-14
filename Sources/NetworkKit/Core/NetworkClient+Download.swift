//
//  NetworkClient+Download.swift
//  NetworkKit
//
//  文件下载：并发限制、进度回调、后台任务保护
//

import Foundation

//MARK: - DownloadProgress
/// 下载进度
public struct DownloadProgress: Sendable {
    /// 已接收字节数
    public let bytesReceived: Int64
    /// 总字节数；服务端未给 Content-Length 时为 nil
    public let totalBytes: Int64?
}

//MARK: - 计算属性
extension DownloadProgress {
    /// 完成比例（0~1）；总长度未知时为 nil
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }
}

//MARK: - 文件下载
extension NetworkClient {
    /// 下载文件到指定本地路径
    /// - Parameters:
    ///   - url: 文件完整地址
    ///   - destination: 保存到的本地文件 URL（目录自动创建，已存在的同名文件会被覆盖）
    ///   - headers: 额外请求头（叠加在配置默认头之上）
    ///   - timeout: 超时（秒）；nil 则用配置默认值
    ///   - configuration: 使用哪份配置（会话、默认头、并发数、事件监听）；默认 `shared`
    ///   - runsInBackgroundTask: 是否在后台任务保护下执行；默认 true
    ///   - progress: 进度回调（在后台线程回调）；传 nil 时走系统整文件下载，效率更高
    /// - Returns: 下载完成后的本地文件 URL
    @discardableResult
    public func download(
        from url: URL,
        to destination: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval? = nil,
        configuration: NetworkConfiguration = .shared,
        runsInBackgroundTask: Bool = true,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        let operation = {
            try await self.performDownload(
                from: url,
                to: destination,
                headers: headers,
                timeout: timeout,
                configuration: configuration,
                progress: progress
            )
        }
        guard runsInBackgroundTask else { return try await operation() }
        return try await BackgroundTaskRunner.run(name: "NetworkKit.download", operation: operation)
    }

    /// 下载文件到指定本地路径（字符串地址版本）
    @discardableResult
    public func download(
        from urlString: String,
        to destination: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval? = nil,
        configuration: NetworkConfiguration = .shared,
        runsInBackgroundTask: Bool = true,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        guard let url = URL(string: urlString) else { throw NetworkError.invalidURL }
        return try await download(
            from: url,
            to: destination,
            headers: headers,
            timeout: timeout,
            configuration: configuration,
            runsInBackgroundTask: runsInBackgroundTask,
            progress: progress
        )
    }
}

//MARK: - 下载实现
private extension NetworkClient {
    /// 实际下载逻辑（受并发限制器约束）
    func performDownload(
        from url: URL,
        to destination: URL,
        headers: [String: String],
        timeout: TimeInterval?,
        configuration: NetworkConfiguration,
        progress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> URL {
        let monitors = configuration.effectiveEventMonitors
        let startTime = Date()
        let semaphore = downloadSemaphore(for: configuration)
        await semaphore.acquire()
        defer { semaphore.release() }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = timeout ?? configuration.defaultTimeout
        var mergedHeaders = configuration.defaultHeaders
        mergedHeaders.removeValue(forKey: "Content-Type")
        for (key, value) in headers { mergedHeaders[key] = value }
        for (key, value) in mergedHeaders { urlRequest.setValue(value, forHTTPHeaderField: key) }

        do {
            let temporaryURL: URL
            if let progress {
                temporaryURL = try await downloadWithProgress(urlRequest, session: configuration.session, progress: progress)
            } else {
                temporaryURL = try await downloadWholeFile(urlRequest, session: configuration.session)
            }
            try moveFile(from: temporaryURL, to: destination)
            monitors.downloadDidFinish(from: url, result: .success(destination), elapsed: Date().timeIntervalSince(startTime))
            return destination
        } catch {
            let networkError = NetworkError.normalize(error)
            monitors.downloadDidFinish(from: url, result: .failure(networkError), elapsed: Date().timeIntervalSince(startTime))
            throw networkError
        }
    }

    /// 走系统整文件下载（无进度）
    func downloadWholeFile(_ urlRequest: URLRequest, session: URLSession) async throws -> URL {
        let (temporaryURL, response) = try await session.download(for: urlRequest)
        try validateDownloadResponse(response, temporaryURL: temporaryURL)
        return temporaryURL
    }

    /// 走字节流下载并回调进度，写到临时文件
    func downloadWithProgress(
        _ urlRequest: URLRequest,
        session: URLSession,
        progress: @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        let (bytes, response) = try await session.bytes(for: urlRequest)
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) == false {
            throw NetworkError.httpStatus(code: http.statusCode, data: Data())
        }
        let totalBytes: Int64? = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkKit-\(UUID().uuidString).download")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var received: Int64 = 0
        var lastReportedBytes: Int64 = 0
        // 每累计 64KB 或结束时刷一次盘并报一次进度，避免逐字节回调
        let reportStep: Int64 = 64 * 1024
        do {
            for try await byte in bytes {
                buffer.append(byte)
                received += 1
                if buffer.count >= reportStep {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if received - lastReportedBytes >= reportStep {
                    lastReportedBytes = received
                    progress(DownloadProgress(bytesReceived: received, totalBytes: totalBytes))
                }
            }
            if buffer.isEmpty == false {
                try handle.write(contentsOf: buffer)
            }
            progress(DownloadProgress(bytesReceived: received, totalBytes: totalBytes ?? received))
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        return temporaryURL
    }

    /// 校验整文件下载的响应状态码，失败时清理临时文件
    func validateDownloadResponse(_ response: URLResponse, temporaryURL: URL) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) == false else { return }
        try? FileManager.default.removeItem(at: temporaryURL)
        throw NetworkError.httpStatus(code: http.statusCode, data: Data())
    }

    /// 确保目标目录存在，覆盖同名文件后把临时文件移过去
    func moveFile(from temporaryURL: URL, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }
}
