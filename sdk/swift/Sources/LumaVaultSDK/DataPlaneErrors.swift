import Connect
import Foundation

/// Maps a failed data plane response onto the same Connect codes the RPCs use.
func dataPlaneError(status: Int, body: Data) -> ConnectError {
    struct GatewayError: Decodable { let error: String }
    let message = (try? JSONDecoder().decode(GatewayError.self, from: body))?.error ?? "HTTP \(status)"
    return ConnectError(code: code(forStatus: status), message: message)
}

func code(forStatus status: Int) -> Code {
    switch status {
    case 400, 413: return .invalidArgument
    case 401: return .unauthenticated
    case 403: return .permissionDenied
    case 404: return .notFound
    case 500: return .internalError
    case 500...: return .unavailable
    default: return .unknown
    }
}

/// Wraps a URLSession failure such as a dropped connection. Cancellation keeps its own code.
func networkError(_ error: Error) -> ConnectError {
    if let connect = error as? ConnectError {
        return connect
    }
    if error is CancellationError || (error as? URLError)?.code == .cancelled {
        return ConnectError(code: .canceled, message: "request canceled", exception: error)
    }
    return ConnectError(code: .unavailable, message: "network request failed", exception: error)
}

func hashMismatch(_ what: String) -> ConnectError {
    ConnectError(code: .dataLoss, message: "\(what) does not match its SHA-256")
}
