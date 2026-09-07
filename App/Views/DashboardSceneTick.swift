import AudioToolbox
import Foundation

/// 轮盘 / 螺旋转动的金属齿轮咔哒声：用参考主题（card-roulette）自带的 tick.wav，
/// 走系统短音接口，静音拨片下不出声；两次咔哒至少隔 36ms（参考 MIN_TICK_GAP）。
enum DashboardSceneTick {
    private static let minimumGap: TimeInterval = 0.036
    /// 螺旋横向倾斜每转过这么多度咔哒一声（参考 TILT_TICK_STEP）。
    static let tiltStepDegrees = 3.2

    private static let soundID: SystemSoundID? = {
        guard let url = Bundle.main.url(forResource: "SceneTick", withExtension: "wav") else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else { return nil }
        return id
    }()

    nonisolated(unsafe) private static var lastPlayedAt: TimeInterval = 0

    @MainActor
    static func play() {
        guard let soundID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPlayedAt >= minimumGap else { return }
        lastPlayedAt = now
        AudioServicesPlaySystemSound(soundID)
    }
}
