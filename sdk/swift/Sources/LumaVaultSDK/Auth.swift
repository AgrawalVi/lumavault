import Connect
import Foundation

// Storage ticket credentials. Apple apps only ever hold tickets; the service key stays on the server.
enum TicketAuth {
    static let authorizationHeader = "Authorization"
    static let tokenQueryItem = "token"

    /// Connect headers that carry a ticket, or none when there is no ticket.
    static func rpcHeaders(ticket: String?) -> Connect.Headers {
        guard let ticket else { return [:] }
        return [authorizationHeader: ["Bearer \(ticket)"]]
    }

    /// Adds the ticket to a data plane request.
    static func apply(ticket: String?, to request: inout URLRequest) {
        if let ticket {
            request.setValue("Bearer \(ticket)", forHTTPHeaderField: authorizationHeader)
        }
    }
}
