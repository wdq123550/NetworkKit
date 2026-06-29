//
//  DESCrypto.swift
//  NetworkKit
//
//  对称加密算法封装（AES / DES / 3DES / RC2 / RC4 / Blowfish 等）
//

import CommonCrypto
import Foundation

public enum CryptoAlgorithm {
    /// 加密的枚举选项 AES/AES128/DES/DES3/CAST/RC2/RC4/Blowfish......
    case AES, AES128, DES, DES3, CAST, RC2, RC4, Blowfish
    var algorithm: CCAlgorithm {
        var result: UInt32 = 0
        switch self {
        case .AES: result = UInt32(kCCAlgorithmAES)
        case .AES128: result = UInt32(kCCAlgorithmAES128)
        case .DES: result = UInt32(kCCAlgorithmDES)
        case .DES3: result = UInt32(kCCAlgorithm3DES)
        case .CAST: result = UInt32(kCCAlgorithmCAST)
        case .RC2: result = UInt32(kCCAlgorithmRC2)
        case .RC4: result = UInt32(kCCAlgorithmRC4)
        case .Blowfish: result = UInt32(kCCAlgorithmBlowfish)
        }
        return CCAlgorithm(result)
    }

    var keyLength: Int {
        var result = 0
        switch self {
        case .AES: result = kCCKeySizeAES128
        case .AES128: result = kCCKeySizeAES256
        case .DES: result = kCCKeySizeDES
        case .DES3: result = kCCKeySize3DES
        case .CAST: result = kCCKeySizeMaxCAST
        case .RC2: result = kCCKeySizeMaxRC2
        case .RC4: result = kCCKeySizeMaxRC4
        case .Blowfish: result = kCCKeySizeMaxBlowfish
        }
        return Int(result)
    }

    var cryptLength: Int {
        var result = 0
        switch self {
        case .AES: result = kCCKeySizeAES128
        case .AES128: result = kCCBlockSizeAES128
        case .DES: result = kCCBlockSizeDES
        case .DES3: result = kCCBlockSize3DES
        case .CAST: result = kCCBlockSizeCAST
        case .RC2: result = kCCBlockSizeRC2
        case .RC4: result = kCCBlockSizeRC2
        case .Blowfish: result = kCCBlockSizeBlowfish
        }
        return Int(result)
    }
}

// MARK: - data

public extension Data {
    /*
     加密
     - parameter algorithm: 加密方式
     - parameter keyData:   加密key

     - return NSData: 加密后的数据 可选值
     */
    mutating func enCrypt(algorithm: CryptoAlgorithm, keyData: Data) -> Data? {
        return crypt(algorithm: algorithm, operation: CCOperation(kCCEncrypt), keyData: keyData)
    }

    /*
     解密
     - parameter algorithm: 解密方式
     - parameter keyData:   解密key

     - return NSData: 解密后的数据  可选值
     */
    mutating func deCrypt(algorithm: CryptoAlgorithm, keyData: Data) -> Data? {
        return crypt(algorithm: algorithm, operation: CCOperation(kCCDecrypt), keyData: keyData)
    }

    /*
     解密和解密方法的抽取的封装方法
     - parameter algorithm: 何种加密方式
     - parameter operation: 加密和解密
     - parameter keyData:   加密key

     - return NSData: 解密后的数据  可选值
     */
    internal mutating func crypt(algorithm: CryptoAlgorithm, operation: CCOperation, keyData: Data) -> Data? {
        let keyLength = Int(algorithm.keyLength)
        let dataLength = count
        let cryptLength = Int(dataLength + algorithm.cryptLength)
        let cryptPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: cryptLength)
        let algoritm = CCAlgorithm(algorithm.algorithm)
        let option = CCOptions(kCCOptionECBMode + kCCOptionPKCS7Padding)
        let numBytesEncrypted = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        numBytesEncrypted.initialize(to: 0)

        #if swift(>=5.0)

            var cryptStatus: CCCryptorStatus!

            withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in

                keyData.withUnsafeBytes {
                    cryptStatus = CCCrypt(operation, algoritm, option, $0.baseAddress, keyLength, nil, bytes.baseAddress, dataLength, cryptPointer, cryptLength, numBytesEncrypted)
                }
            }

        #elseif swift(>=4.2) && compiler(>=5.0)

            let keyBytes: [Int8] = keyData.withUnsafeBytes { (bytes: UnsafePointer<Int8>) -> [Int8] in
                let buffer = UnsafeBufferPointer(start: bytes, count: keyLength)
                return Array(buffer)
            }

            let dataBytes: [Int8] = withUnsafeBytes { (bytes: UnsafePointer<Int8>) -> [Int8] in
                let buffer = UnsafeBufferPointer(start: bytes, count: dataLength)
                return Array(buffer)
            }

            let cryptStatus = CCCrypt(operation, algoritm, option, keyBytes, keyLength, nil, dataBytes, dataLength, cryptPointer, cryptLength, numBytesEncrypted)

        #else

            var keyBytes: UnsafePointer<Int8>?
            keyData.withUnsafeBytes { (bytes: UnsafePointer<Int8>) in
                keyBytes = bytes
            }

            var dataBytes: UnsafePointer<Int8>?
            withUnsafeBytes { (bytes: UnsafePointer<CChar>) in
                //            print(bytes)
                dataBytes = bytes
            }

            let cryptStatus = CCCrypt(operation, algoritm, option, keyBytes, keyLength, nil, dataBytes, dataLength, cryptPointer, cryptLength, numBytesEncrypted)

        #endif

        if CCStatus(cryptStatus) == CCStatus(kCCSuccess) {
            let len = Int(numBytesEncrypted.pointee)
            let data = Data(bytes: cryptPointer, count: len)
            numBytesEncrypted.deallocate()
            return data
        } else {
            numBytesEncrypted.deallocate()
            cryptPointer.deallocate()
            return nil
        }
    }
}
