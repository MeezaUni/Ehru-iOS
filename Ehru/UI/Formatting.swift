import Foundation

extension TimeInterval {
    /// 3:07, or 1:02:09 for anything an hour or longer.
    var formattedDuration: String {
        guard isFinite, self > 0 else { return "0:00" }
        let total = Int(rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
