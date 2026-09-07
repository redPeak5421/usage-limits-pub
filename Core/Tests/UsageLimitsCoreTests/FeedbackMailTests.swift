import Foundation
import XCTest
@testable import UsageLimitsCore

final class FeedbackMailTests: XCTestCase {
    func testDraftPrefillsRequiredRecipientSubjectAndEditableBody() {
        XCTAssertEqual(FeedbackMailDraft.recipient, "canonforge5421@gmail.com")
        XCTAssertEqual(FeedbackMailDraft.subject(for: .en), "Usage Limits feedback: [Add a short summary]")
        XCTAssertEqual(
            FeedbackMailDraft.body(for: .en),
            "Source: Usage Limits\n\nPlease describe your feedback below:\n\n"
        )
    }

    func testDiagnosticAttachmentExportsLinesInOrderAsUTF8Text() throws {
        let data = FeedbackMailDraft.diagnosticAttachment(from: [
            "[2026-09-01T10:00:00Z] first",
            "[2026-09-01T10:00:01Z] second",
        ])

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "[2026-09-01T10:00:00Z] first\n[2026-09-01T10:00:01Z] second"
        )
        XCTAssertEqual(FeedbackMailDraft.attachmentMIMEType, "text/plain")
        XCTAssertEqual(FeedbackMailDraft.attachmentFileName, "usage-limits-diagnostics.txt")
    }

    func testSubjectAndBodyFollowAppLanguage() {
        XCTAssertEqual(FeedbackMailDraft.subject(for: .zh), "Usage Limits 反馈：[请填一句概述]")
        XCTAssertTrue(FeedbackMailDraft.body(for: .zh).hasPrefix("来源：Usage Limits"))
        XCTAssertTrue(FeedbackMailDraft.body(for: .zh).hasSuffix("\n\n"), "正文末尾留空行给用户写")
        for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
            XCTAssertTrue(FeedbackMailDraft.subject(for: lang).contains("Usage Limits"), "主题须带 App 名 \(lang.rawValue)")
            XCTAssertTrue(FeedbackMailDraft.body(for: lang).contains("Usage Limits"), "正文须带来源 \(lang.rawValue)")
        }
    }

    func testEmptyDiagnosticAttachmentExplainsThatNoLogsExist() {
        let data = FeedbackMailDraft.diagnosticAttachment(from: [])

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "No diagnostic logs recorded.\n")
    }

    func testFeedbackCopyExistsInEverySupportedLanguage() {
        let keys = [
            "settings.feedback",
            "feedback.logs.prompt",
            "feedback.logs.disclosure",
            "feedback.logs.include",
            "feedback.logs.exclude",
            "feedback.mail.unavailable.title",
            "feedback.mail.unavailable.message",
            "feedback.mail.failed.title",
            "feedback.mail.failed.message",
            "feedback.cancel",
            "feedback.mail.subject",
            "feedback.mail.body",
        ]
        for key in keys {
            for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
                XCTAssertNotEqual(L10n.tr(key, lang), key, "\(key) missing \(lang.rawValue)")
            }
        }
    }

    func testSettingsFeedbackFlowOffersOptionalDiagnosticsAndMailFailureHandling() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: root.appendingPathComponent("App/Views/SettingsView.swift"),
            encoding: .utf8
        )
        let composerURL = root.appendingPathComponent("App/Views/FeedbackMailComposer.swift")

        XCTAssertTrue(settings.contains("L10n.tr(\"settings.feedback\""), "Settings must expose localized Feedback")
        XCTAssertFalse(settings.contains("confirmationDialog"), "Feedback options must not use an anchored popover")
        XCTAssertTrue(
            settings.contains("FeedbackMailDraft.diagnosticAttachment(from: state.store.diagnostics())"),
            "Include Logs must snapshot stored diagnostics into the attachment data"
        )
        XCTAssertTrue(settings.contains("FeedbackMailComposer"), "Both choices must use the system composer")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: composerURL.path),
            "Feedback must provide the MessageUI composer bridge"
        )
        guard FileManager.default.fileExists(atPath: composerURL.path) else { return }

        let composer = try String(contentsOf: composerURL, encoding: .utf8)
        XCTAssertTrue(composer.contains("MFMailComposeViewController.canSendMail()"))
        XCTAssertTrue(composer.contains("setToRecipients([FeedbackMailDraft.recipient])"))
        XCTAssertTrue(composer.contains("setSubject(FeedbackMailDraft.subject(for: language))"), "主题须按 App 语言")
        XCTAssertTrue(composer.contains("setMessageBody(FeedbackMailDraft.body(for: language), isHTML: false)"), "正文须按 App 语言")
        XCTAssertTrue(
            settings.contains("let language = lang.resolved") && settings.contains("language: language,"),
            "设置页须把当前 App 语言传给撰写器"
        )
        XCTAssertTrue(composer.contains("addAttachmentData"))
        XCTAssertTrue(composer.contains("FeedbackMailDraft.attachmentMIMEType"))
        XCTAssertTrue(composer.contains("FeedbackMailDraft.attachmentFileName"))
        XCTAssertTrue(composer.contains("mailComposeController"), "Composer delegate must dismiss the sheet")
        XCTAssertTrue(composer.contains(".failed"), "Compose failures must be surfaced")
    }

    func testFeedbackOptionsFitContentWithoutFlexibleGap() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: root.appendingPathComponent("App/Views/SettingsView.swift"),
            encoding: .utf8
        )
        let optionsURL = root.appendingPathComponent("App/Views/FeedbackOptionsSheet.swift")

        XCTAssertFalse(settings.contains("confirmationDialog"), "Feedback must never return to a popover menu")
        XCTAssertTrue(settings.contains("FeedbackOptionsSheet"), "Feedback must present the dedicated bottom sheet")
        XCTAssertTrue(
            settings.contains("onDismiss: presentPendingFeedback"),
            "Mail composition must wait until the options sheet has fully dismissed"
        )
        XCTAssertTrue(settings.contains("pendingFeedbackIncludesDiagnostics"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: optionsURL.path),
            "Feedback must provide a dedicated bottom-sheet view"
        )
        guard FileManager.default.fileExists(atPath: optionsURL.path) else { return }

        let options = try String(contentsOf: optionsURL, encoding: .utf8)
        XCTAssertFalse(options.contains(".height(280)"), "Normal layout must not guess a fixed height")
        XCTAssertFalse(options.contains("if #available(iOS 18.0, *)"))
        XCTAssertFalse(
            options.contains(".presentationSizing"),
            "iPhone ignores fitted presentation sizing for compact bottom sheets"
        )
        XCTAssertTrue(
            options.contains(".presentationDetents([.medium])"),
            "Accessibility text sizes must retain a scrollable medium sheet"
        )
        XCTAssertTrue(options.contains(".height(compactHeight)"))
        XCTAssertTrue(options.contains("FeedbackSheetHeightKey"))
        XCTAssertTrue(options.contains("geometry.safeAreaInsets.bottom"))
        XCTAssertTrue(options.contains("contentHeight - bottomSafeAreaInset"))
        XCTAssertTrue(options.contains(".ignoresSafeArea(.container, edges: .bottom)"))
        XCTAssertFalse(options.contains("- 34"), "Bottom inset must be measured, never hard-coded")
        XCTAssertTrue(options.contains("dynamicTypeSize.isAccessibilitySize"))
        XCTAssertFalse(options.contains("Spacer("), "Options must not reserve an empty flexible gap")
        XCTAssertTrue(
            options.contains("VStack(alignment: .leading, spacing: 12)"),
            "Vertical content spacing must stay compact"
        )
        XCTAssertTrue(options.contains(".padding(.horizontal, 24)"))
        XCTAssertTrue(options.contains(".padding(.vertical, 16)"))
        XCTAssertFalse(options.contains(".padding(24)"), "Sheet must not retain oversized bottom padding")
        XCTAssertTrue(options.contains("ScrollView {"), "Large text must remain vertically scrollable")
        XCTAssertTrue(options.contains("minHeight: 44"), "Cancel must retain a 44-point touch target")
        XCTAssertTrue(
            options.contains("Text(L10n.tr(\"feedback.cancel\""),
            "Cancel sizing must be applied inside its label"
        )
        XCTAssertTrue(
            options.contains(".contentShape(Rectangle())"),
            "The full 44-point Cancel label must be tappable"
        )
        XCTAssertTrue(options.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(options.contains(".accessibilityAddTraits(.isHeader)"))
        XCTAssertTrue(options.contains(".presentationDragIndicator(.visible)"))
        XCTAssertTrue(options.contains("feedback.logs.prompt"))
        XCTAssertTrue(options.contains("feedback.logs.disclosure"))
        XCTAssertTrue(options.contains("feedback.logs.include"))
        XCTAssertTrue(options.contains("feedback.logs.exclude"))
        XCTAssertTrue(options.contains("feedback.cancel"))
    }
}
