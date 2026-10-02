import SwiftUI
import VisionKit

struct AddFriendView: View {
    let store: FriendsStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isSending = false
    @State private var error: String?
    @State private var result: String?
    @State private var showScanner = false

    private var canScan: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ABC-123", text: $code)
                        .font(.title2.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await send() } }
                } header: {
                    Text("Friend's code")
                } footer: {
                    Text("Ask your friend for the code at the top of their Friends tab.")
                }

                if canScan {
                    Section {
                        Button { showScanner = true } label: { Label("Scan QR Code", systemImage: "qrcode.viewfinder") }
                    }
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                if let result {
                    Section { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            }
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await send() } }
                            .bold()
                            .disabled(FriendCode.normalize(code).count < 6)
                    }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                NavigationStack {
                    QRScannerView { scanned in
                        showScanner = false
                        code = FriendCode.format(FriendCode.normalize(scanned))
                        Task { await send() }
                    }
                    .ignoresSafeArea()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScanner = false } }
                    }
                }
            }
        }
    }

    private func send() async {
        let normalized = FriendCode.normalize(code)
        guard normalized.count >= 6, !isSending else { return }
        error = nil
        result = nil
        isSending = true
        defer { isSending = false }
        do {
            let status = try await store.addFriend(code: normalized)
            result = status == "accepted" ? "You're now friends!" : "Request sent. They'll see it in their Friends tab."
            try? await Task.sleep(for: .seconds(1.2))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Live camera QR scanner (VisionKit). Calls `onScan` once with the first QR payload it sees.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var handled = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !handled else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    handled = true
                    dataScanner.stopScanning()
                    onScan(payload)
                    return
                }
            }
        }
    }
}
