import Connect

extension ResponseMessage {
    /// The response message, or the RPC's ConnectError.
    func unwrap() throws -> Output {
        try result.get()
    }
}
