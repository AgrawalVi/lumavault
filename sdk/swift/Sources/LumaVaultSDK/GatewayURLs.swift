import Foundation

func chunkURL(baseURL: URL, sha256: String) -> URL {
    baseURL.appending(path: GatewayRoutes.chunks).appending(path: sha256)
}

func gatewayStreamURL(baseURL: URL, objectID: String) -> URL {
    baseURL.appending(path: GatewayRoutes.stream).appending(component: objectID)
}
