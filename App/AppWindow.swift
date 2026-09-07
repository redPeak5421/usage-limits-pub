import UIKit

extension UIApplication {
    /// 前台场景的 key window（没有前台场景就退到任一场景 / 任一窗口）。
    @MainActor static var usagelimitsKeyWindow: UIWindow? {
        let scenes = shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
    }

    /// 最上层正在展示的控制器（设置页可能自己就是一层 sheet）。
    @MainActor static var usagelimitsTopViewController: UIViewController? {
        var top = usagelimitsKeyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

enum DeviceScreen {
    @MainActor static var cornerRadius: CGFloat {
        if UIDevice.current.userInterfaceIdiom == .pad { return 18 }
        let topInset = UIApplication.usagelimitsKeyWindow?.safeAreaInsets.top ?? 0
        return topInset > 24 ? 55 : 0
    }
}
