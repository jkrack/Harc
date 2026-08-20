import Foundation
import GRPCCore

public enum HarcForegroundUploadDiagnosticStage: String, Sendable {
    case beginUpload = "begin-upload"
    case beginAccepted = "begin-accepted"
    case chunksDeclared = "chunks-declared"
    case reconcileBeforeUpload = "reconcile-before-upload"
    case uploadChunk = "upload-chunk"
    case chunkDurable = "chunk-durable"
    case reconcileAfterUpload = "reconcile-after-upload"
    case commitUpload = "commit-upload"
    case receiptDurable = "receipt-durable"
}

public struct HarcForegroundUploadDiagnosticEvent: Sendable {
    public let stage: HarcForegroundUploadDiagnosticStage
    public let message: String
    public let chunkIndex: UInt32?
    public let chunkCount: Int
    public let encodedByteCount: UInt64?

    public init(
        stage: HarcForegroundUploadDiagnosticStage,
        message: String,
        chunkIndex: UInt32? = nil,
        chunkCount: Int,
        encodedByteCount: UInt64? = nil
    ) {
        self.stage = stage
        self.message = message
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.encodedByteCount = encodedByteCount
    }
}

public struct HarcTransportErrorDiagnostic: Equatable, Sendable {
    public let type: String
    public let summary: String
    public let rpcCode: String?
    public let rpcCodeNumber: Int?
    public let rpcMessage: String?
    public let cause: String?

    public static func describe(_ error: any Error) -> Self {
        if let rpc = error as? RPCError {
            return Self(
                type: "GRPCCore.RPCError",
                summary: String(describing: rpc),
                rpcCode: rpc.code.description,
                rpcCodeNumber: rpc.code.rawValue,
                rpcMessage: rpc.message,
                cause: rpc.cause.map { String(describing: $0) }
            )
        }
        return Self(
            type: String(reflecting: Swift.type(of: error)),
            summary: String(describing: error),
            rpcCode: nil,
            rpcCodeNumber: nil,
            rpcMessage: nil,
            cause: nil
        )
    }
}
