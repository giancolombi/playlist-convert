import Foundation
import MusicKit

enum AppleMusicAuthorization {
    /// Requests Music library access. First run will trigger the OS permission prompt;
    /// subsequent runs are silent.
    static func ensureAuthorized() async throws {
        let current = MusicAuthorization.currentStatus
        if current == .authorized { return }

        let result = await MusicAuthorization.request()
        guard result == .authorized else {
            throw CLIError.userMessage("""
                Apple Music access not granted (status: \(describe(result))).
                Open System Settings → Privacy & Security → Media & Apple Music
                and enable PlaylistConvert. Make sure you are signed into Apple Music
                in the Music app.
                """)
        }
    }

    private static func describe(_ s: MusicAuthorization.Status) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .authorized:    return "authorized"
        @unknown default:    return "unknown"
        }
    }
}
