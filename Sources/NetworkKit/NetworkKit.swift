// The Swift Programming Language
// https://docs.swift.org/swift-book
import Foundation
import Network
import Observation

/// 统一监听系统网络状态，对外只暴露可读的存储属性，由内部在主线程刷新。
@Observable
public final class NetworkObserver {

    private init() {}

    // MARK: - Stored properties

    public static let shared = NetworkObserver()

    /// 当前网络路径状态。初始视为 `.satisfied`，等首次回调后再更新为真实值。
    public private(set) var status: NWPath.Status = .satisfied

    /// 是否检测到 VPN 连接
    public private(set) var isVPNMode: Bool = false

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "NetworkObserverQueue")
    @ObservationIgnored private var hasStarted = false
}

// MARK: - Methods

public extension NetworkObserver {

    /// 开启监听。重复调用是安全的。
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let newStatus = path.status
            let newReachable = newStatus == .satisfied
            // 只要网络路径中有 .other 类型接口，就可能是 VPN
            let usingVPN = path.availableInterfaces.contains { $0.type == .other }

            Task { @MainActor in
                if self.status != newStatus {
                    self.status = newStatus
                }
                if self.isVPNMode != usingVPN {
                    self.isVPNMode = usingVPN
                }
                #if DEBUG
                print("🌐 网络状态: \(newReachable ? "✅ 可用" : "❌ 不可用")，VPN: \(usingVPN ? "✅ 已连接" : "❌ 未连接")")
                #endif
            }
        }
        monitor.start(queue: queue)
    }
}
