/// The Model Context Protocol includes optional progress tracking that allows receive updates about the progress of a request.
/// - Important: When a party wants to receive progress updates for a request, it must (1) include a `progressToken` in that request's metadata and (2) subscribe to `ProgressNotification` via`onNotification`. See README.md for example usage.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-03-26/basic/utilities/progress
public struct ProgressNotification: Notification {
    public static let name: String = "notifications/progress"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The original progress token.
        public let progressToken: String

        /// The current progress value so far.
        public let progress: Double

        /// An optional “total” progress value.
        public let total: Double?

        /// An optional “message” value.
        public let message: String?

        public init(progressToken: String, progress: Double, total: Double?, message: String?) {
            self.progressToken = progressToken
            self.progress = progress
            self.total = total
            self.message = message
        }
    }
}

