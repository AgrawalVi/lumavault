import Foundation

func gatewayChunkURL(baseURL: URL, sha256: String, ticket: String? = nil) -> URL {
    withTicket(baseURL.appending(path: GatewayRoutes.chunks).appending(path: sha256), ticket)
}

func gatewayStreamURL(baseURL: URL, objectID: String, ticket: String? = nil) -> URL {
    withTicket(baseURL.appending(path: GatewayRoutes.stream).appending(component: objectID), ticket)
}

// AVPlayer and image views cannot send headers, so their URLs carry the ticket instead.
private func withTicket(_ url: URL, _ ticket: String?) -> URL {
    guard let ticket else { return url }
    return url.appending(queryItems: [URLQueryItem(name: TicketAuth.tokenQueryItem, value: ticket)])
}
