//
//  NetworkObserver.swift
//  NetworkKit
//
//  网络连接观察者
//

import Foundation
import Network
import CoreTelephony
import Observation

// MARK: - 枚举定义
/// 蜂窝网络制式
public enum CellularGeneration: Equatable {
    /// 2G（GPRS / Edge / CDMA1x）
    case g2
    /// 3G（WCDMA / HSDPA / EVDO 等）
    case g3
    /// 4G（LTE）
    case g4
    /// 5G（NR / NRNSA）
    case g5
    /// 未知制式
    case unknown

    /// 埋点用的展示名称
    public var description: String {
        switch self {
        case .g2: return "2G"
        case .g3: return "3G"
        case .g4: return "4G"
        case .g5: return "5G"
        case .unknown: return "Cellular"
        }
    }
}

/// 当前物理网络类型（与 VPN 状态相互独立）
public enum NetworkType: Equatable {
    /// 无网络连接
    case noConnection
    /// WiFi 网络
    case wifi
    /// 蜂窝网络（关联具体制式）
    case cellular(CellularGeneration)
    /// 未知网络类型
    case unknown

    /// 埋点用的展示名称
    public var description: String {
        switch self {
        case .noConnection: return "No Connection"
        case .wifi: return "WiFi"
        case .cellular(let generation): return generation.description
        case .unknown: return "Unknown"
        }
    }
}

@Observable
public final class NetworkObserver {
    // MARK: - 存储属性
    /// 单例实例
    public static let shared = NetworkObserver()
    private init() {
        setupPathMonitor()
    }
    /// 当前网络状态
    private var currentStatus: NWPath.Status = .requiresConnection
    /// 当前网络路径
    private var currentPath: NWPath?
    /// 网络路径监听器
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// 后台监听队列
    @ObservationIgnored private let queue = DispatchQueue(label: "NetworkObserver")
    /// 蜂窝网络信息（用于解析具体制式）
    @ObservationIgnored private let networkInfo = CTTelephonyNetworkInfo()
    /// 是否已启动监听（防止重复 start 导致回调队列异常）
    @ObservationIgnored private var didStartMonitoring = false
}

// MARK: - 计算属性
extension NetworkObserver {
    /// 网络是否可用
    public var isNetworkAvailable: Bool {
        currentStatus == .satisfied
    }
    /// 当前物理网络类型（WiFi / 蜂窝等，不受 VPN 影响；蜂窝带具体制式）
    public var networkType: NetworkType {
        resolveNetworkType(path: currentPath, status: currentStatus)
    }
    /// 当前是否处于 VPN 连接状态
    public var isVPNActive: Bool {
        Self.resolveVPNActive(path: currentPath, status: currentStatus)
    }
    /// 解析当前蜂窝网络制式
    private var currentCellularGeneration: CellularGeneration {
        guard let radioTechnology = networkInfo.serviceCurrentRadioAccessTechnology?.values.first else {
            return .unknown
        }
        switch radioTechnology {
        case CTRadioAccessTechnologyGPRS,
             CTRadioAccessTechnologyEdge,
             CTRadioAccessTechnologyCDMA1x:
            return .g2
        case CTRadioAccessTechnologyWCDMA,
             CTRadioAccessTechnologyHSDPA,
             CTRadioAccessTechnologyHSUPA,
             CTRadioAccessTechnologyCDMAEVDORev0,
             CTRadioAccessTechnologyCDMAEVDORevA,
             CTRadioAccessTechnologyCDMAEVDORevB,
             CTRadioAccessTechnologyeHRPD:
            return .g3
        case CTRadioAccessTechnologyLTE:
            return .g4
        case CTRadioAccessTechnologyNRNSA,
             CTRadioAccessTechnologyNR:
            return .g5
        default:
            return .unknown
        }
    }
}

// MARK: - 方法
extension NetworkObserver {
    /// 开始监听网络状态（仅启动一次）
    public func beginObservation() {
        guard !didStartMonitoring else { return }
        didStartMonitoring = true
        #if DEBUG
        print("[debugLog] NetworkObserver开始监听网络路径✅️")
        #endif
        pathMonitor.start(queue: queue)
    }

    /// 配置网络路径监听（仅设置回调，启动交由 beginObservation）
    private func setupPathMonitor() {
        #if DEBUG
        print("[debugLog] NetworkObserver开始配置网络路径监听✅️")
        #endif
        pathMonitor.pathUpdateHandler = { newPath in
            // 始终切回主线程更新可观察状态：
            // @Observable 的变更通知在 willSet 时同步触发，跨线程写入会与主线程观察者的重新读取产生竞态，
            // 导致主线程读到旧值后再也收不到通知。在主线程写入可消除该竞态。
            DispatchQueue.main.async {
                NetworkObserver.shared.applyPathUpdate(newPath)
            }
        }
    }

    /// 在主线程应用网络路径变更并更新可观察状态
    private func applyPathUpdate(_ newPath: NWPath) {
        let newStatus = newPath.status
        let newType = resolveNetworkType(path: newPath, status: newStatus)
        let newVPN = Self.resolveVPNActive(path: newPath, status: newStatus)
        let oldStatus = currentStatus
        let oldType = resolveNetworkType(path: currentPath, status: oldStatus)
        let oldVPN = Self.resolveVPNActive(path: currentPath, status: oldStatus)
        let oldAvailable = oldStatus == .satisfied
        let newAvailable = newStatus == .satisfied

        currentPath = newPath
        currentStatus = newStatus

        guard oldAvailable != newAvailable || oldType != newType || oldVPN != newVPN else { return }
        #if DEBUG
        if oldAvailable != newAvailable {
            print("[debugLog] NetworkObserver网络可用性变化：\(oldAvailable ? "可用" : "不可用") → \(newAvailable ? "可用" : "不可用")✅️")
        }
        if oldType != newType {
            print("[debugLog] NetworkObserver网络类型变化：\(oldType.description) → \(newType.description)✅️")
        }
        if oldVPN != newVPN {
            print("[debugLog] NetworkObserver VPN状态变化：\(oldVPN ? "已连接" : "未连接") → \(newVPN ? "已连接" : "未连接")✅️")
        }
        #endif
    }

    /// 根据网络路径解析物理网络类型（忽略 VPN 叠加层，回落到底层物理接口）
    private func resolveNetworkType(path: NWPath?, status: NWPath.Status) -> NetworkType {
        guard let path, status == .satisfied else {
            return .noConnection
        }
        // 走 VPN 时主接口为 other，需从可用接口推断真实物理类型
        if path.usesInterfaceType(.wifi)
            || path.availableInterfaces.contains(where: { $0.type == .wifi }) {
            return .wifi
        }
        if path.usesInterfaceType(.cellular)
            || path.availableInterfaces.contains(where: { $0.type == .cellular }) {
            return .cellular(currentCellularGeneration)
        }
        return .unknown
    }

    /// 根据网络路径判断是否处于 VPN 连接状态
    private static func resolveVPNActive(path: NWPath?, status: NWPath.Status) -> Bool {
        guard let path, status == .satisfied else {
            return false
        }
        // VPN 隧道在 NWPath 中主接口表现为 other 类型；NWPath 无法 100% 精确识别 VPN，这里取够用的近似判断
        return path.usesInterfaceType(.other)
    }
}
