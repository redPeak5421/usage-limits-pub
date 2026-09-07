import AudioToolbox
import UIKit

/// 模拟 Apple Watch 数码表冠的一格滴答：短促系统音 + 选中触感。
enum CrownTick {
    private static let clickSound: SystemSoundID = 1104
    private static let haptic = UISelectionFeedbackGenerator()

    static func prepare() {
        haptic.prepare()
    }

    static func play() {
        haptic.selectionChanged()
        haptic.prepare()
        AudioServicesPlaySystemSound(clickSound)
    }
}
