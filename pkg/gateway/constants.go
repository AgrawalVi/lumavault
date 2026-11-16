package gateway

const (
	// controlPlaneReadMaxBytes caps a single Connect-RPC request message at 1 MiB.
	controlPlaneReadMaxBytes = 1 << 20

	contentTypeJSON        = "application/json"
	contentTypeOctetStream = "application/octet-stream"

	// chunkCacheControl lets clients and proxies cache chunks forever, since a chunk's
	// bytes can never change under its SHA-256 name.
	chunkCacheControl = "public, max-age=31536000, immutable"

	corsAllowOrigin  = "*"
	corsAllowMethods = "GET, HEAD, POST, PUT, OPTIONS"
	corsAllowHeaders = "Range, If-Range, If-None-Match, Content-Type, Connect-Protocol-Version, " +
		"Connect-Timeout-Ms, Connect-Accept-Encoding, Grpc-Timeout, X-Grpc-Web"
	corsExposeHeaders = "Content-Range, Accept-Ranges, Content-Length, ETag, " +
		"Connect-Content-Encoding, Grpc-Status, Grpc-Message"
)
