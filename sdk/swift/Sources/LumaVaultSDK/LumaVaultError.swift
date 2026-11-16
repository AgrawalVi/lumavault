import Connect
import Foundation

/// Errors thrown by the LumaVault Swift SDK across chunk planning, HTTP data plane transfers,
/// and Connect-RPC control plane calls.
public enum LumaVaultError: Error, Sendable, Equatable, LocalizedError {
    case invalidNamespace(Lumavault_V1_Namespace)
    case invalidChunkSize(Int)
    case invalidHash(String)
    case hashMismatch(expected: String, actual: String)
    case payloadTooLarge(sizeBytes: Int64, maxBytes: Int64)
    case httpError(statusCode: Int, message: String)
    case rpcError(code: Connect.Code, message: String?)
    case emptyUpdateMask
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidNamespace(let namespace):
            return "Invalid LumaVault namespace: \(namespace)"
        case .invalidChunkSize(let size):
            return "Invalid chunk size \(size) bytes; expected \(Chunker.minChunkSizeBytes)...\(Chunker.maxChunkSizeBytes)"
        case .invalidHash(let hash):
            return "Invalid SHA-256 hex digest: \(hash)"
        case .hashMismatch(let expected, let actual):
            return "SHA-256 digest mismatch: expected \(expected), got \(actual)"
        case .payloadTooLarge(let sizeBytes, let maxBytes):
            return "Payload size \(sizeBytes) bytes exceeds limit of \(maxBytes) bytes"
        case .httpError(let statusCode, let message):
            return message.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode): \(message)"
        case .rpcError(let code, let message):
            if let message, !message.isEmpty {
                return "RPC \(code.name): \(message)"
            }
            return "RPC \(code.name)"
        case .emptyUpdateMask:
            return "UpdateObjectMetadata requires at least one field in update_mask"
        case .invalidResponse(let detail):
            return "Invalid server response: \(detail)"
        }
    }
}
