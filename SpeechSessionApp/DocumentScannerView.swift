import SwiftUI
import VisionKit

/// SwiftUI wrapper around `VNDocumentCameraViewController`.
/// Presents Apple's built-in document scanner UI (same as Notes).
struct DocumentScannerView: UIViewControllerRepresentable {
    /// Called on the main thread when scanning finishes, fails, or is cancelled.
    /// `.failure` is only delivered on an actual error — cancellation calls the closure with nil.
    let onCompletion: (VNDocumentCameraScan?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    // MARK: - Delegate

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onCompletion: (VNDocumentCameraScan?) -> Void

        init(onCompletion: @escaping (VNDocumentCameraScan?) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            onCompletion(scan)
        }

        func documentCameraViewControllerDidCancel(
            _ controller: VNDocumentCameraViewController
        ) {
            onCompletion(nil)   // nil signals cancellation
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            onCompletion(nil)   // dismiss and let the caller surface an error if needed
        }
    }
}
