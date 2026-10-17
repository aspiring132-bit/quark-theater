import Foundation

struct RetryPolicy {
    let maximumRetries: Int
    let baseDelay: TimeInterval

    init(maximumRetries: Int = 2, baseDelay: TimeInterval = 1) {
        self.maximumRetries = max(0, maximumRetries)
        self.baseDelay = max(0, baseDelay)
    }

    /// Only retry transport failures and server outages, never permission/risk-control failures.
    func delay(for error: Error, retriesUsed: Int) -> TimeInterval? {
        guard retriesUsed >= 0, retriesUsed < maximumRetries else { return nil }
        if let error = error as? QuarkError {
            if case .httpStatus(let status) = error, (500...599).contains(status) {
                return baseDelay * pow(2, Double(retriesUsed))
            }
            return nil
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(nsError.code) {
            return baseDelay * pow(2, Double(retriesUsed))
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== nsError {
            // One level only: an arbitrary NSError chain may contain cycles.
            if underlying.domain == NSURLErrorDomain,
               [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet].contains(underlying.code) {
                return baseDelay * pow(2, Double(retriesUsed))
            }
        }
        return nil
    }
}
