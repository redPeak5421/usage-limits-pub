import Foundation

/// 分享预览底部固定栏的目标。
///
/// 微信在 iOS 上的能力边界（2026-08 调研，见微信开放平台文档）：
/// - `weixin://dl/moments` 等功能深链 2017 年起全部废弃，只能打开微信首页；
/// - 不接入微信 OpenSDK（需开放平台 AppID + Universal Links 域名）无法直接
///   拉起「发送给朋友 / 发布朋友圈」界面；
/// - 无 SDK 的最优路径：微信 = 系统分享面板中的微信扩展（带图直达选人页）；
///   朋友圈 = 存相册 + 指引用户从相册选图发布。
public enum ShareTarget: String, CaseIterable, Identifiable, Sendable, Equatable {
    case edit
    case wechat
    case moments
    case more
    case saveToPhotos

    public var id: String { rawValue }

    /// 底栏展示的目标；`SharePreviewSheet.shareBar` 按同一顺序写死按钮（契约测试要求源码里
    /// 保留注释掉的微信 / 朋友圈行，两处一起改）。不要用 filter / if 在运行时隐藏，避免编译后仍留下
    /// 可执行分支；case、处理逻辑与品牌素材全部保留，打开对应注释即恢复。
    public static var visibleCases: [ShareTarget] {
        [
            .edit,
            // .wechat,
            // .moments,
            .more,
            .saveToPhotos,
        ]
    }

    public var l10nKey: String {
        switch self {
        case .edit: return "share.target.edit"
        case .wechat: return "share.target.wechat"
        case .moments: return "share.target.moments"
        case .more: return "share.target.other"
        case .saveToPhotos: return "share.target.save"
        }
    }

    public var systemImage: String {
        switch self {
        case .edit: return "square.and.pencil"
        case .wechat: return "message.fill"
        case .moments: return "person.2.fill"
        case .more: return "square.and.arrow.up"
        case .saveToPhotos: return "square.and.arrow.down"
        }
    }

    /// 微信 / 朋友圈用品牌图；编辑、分享与保存用系统符号。
    public var assetName: String? {
        switch self {
        case .wechat: return "LogoWeChat"
        case .moments: return "LogoMoments"
        case .edit, .more, .saveToPhotos: return nil
        }
    }
}

/// 全局分享管理钮文案：展开态显示三个芯片并标「分享展开」；点成折叠后隐藏芯片并标「分享折叠」。
public enum ShareManageLabel {
    public static func l10nKey(chipsVisible: Bool) -> String {
        chipsVisible ? "share.manage.expand" : "share.manage.collapse"
    }
}
