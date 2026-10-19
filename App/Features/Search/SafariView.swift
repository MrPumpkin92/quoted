import SafariServices
import SwiftUI

/// Google, opened inside Quoted from the search tab's web row (docs/ui-spec.md §9).
///
/// The founder chose the in-app browser over handing off to the Safari app
/// (docs/decisions/2026-10-19-web-search-browser.md). An in-app browser counts as unrestricted
/// web access, so App Store Connect's age rating must answer "Unrestricted Web Access: Yes"
/// (docs/app-store-submission.md).
struct SafariView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    init(url: URL) {
        self.url = url
    }

    var body: some View {
        SafariController(url: url) { dismiss() }
            .ignoresSafeArea()
    }
}

/// The `SFSafariViewController` itself. Its Close button reports through the delegate, which
/// dismisses the sheet.
private struct SafariController: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency SFSafariViewControllerDelegate {
        var onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onFinish()
        }
    }
}
