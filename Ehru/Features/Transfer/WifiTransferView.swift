import CoreImage.CIFilterBuiltins
import SwiftUI

/// Wi-Fi Transfer: receive music from a computer's browser over the local network.
struct WifiTransferView: View {
    @Environment(WifiTransferStore.self) private var transfer
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.palette) private var palette

    var body: some View {
        List {
            Section {
                status
                switch transfer.state {
                case .running(let address, let pairingUrl, let code):
                    running(address: address, url: pairingUrl, code: code)
                case .starting:
                    Button("Starting…") {}.disabled(true)
                case .stopped:
                    Text("Starting opens a temporary, private transfer page on this Wi-Fi network only. It stops when you stop it, when Wi-Fi disconnects, when you leave empee3, or after 10 minutes without activity.")
                        .font(.subheadline)
                    Button { transfer.start() } label: { Label("Start transfer", systemImage: "wifi") }
                }
            }
            if !transfer.items.isEmpty {
                Section {
                    let counts = transfer.counts
                    HStack(spacing: Spacing.md) {
                        Text("\(counts.saved) saved").foregroundStyle(Color.accentColor)
                        if counts.duplicates > 0 { Text("\(counts.duplicates) already on phone") }
                        if counts.failed > 0 { Text("\(counts.failed) not saved").foregroundStyle(.red) }
                    }
                    .font(.subheadline.weight(.semibold))
                    ForEach(transfer.items.reversed()) { item in itemRow(item) }
                } header: {
                    Text("This session")
                }
            }
            Section("How to connect") {
                help("1. Put the phone and the computer on the same Wi-Fi network.")
                help("2. Tap Start transfer, then scan the QR code or type the address in the computer's browser.")
                help("3. Choose files or a folder (or drag them in) and press Send to phone.")
                help("Music is saved to empee3's folder (Files › On My iPhone › empee3) and appears in your library shortly after.")
                help("Keep empee3 open while sending: iOS pauses the transfer when the app is in the background.")
            }
            Section("If the page does not load") {
                help("Check both devices use the same network (not a guest network: those often block devices from seeing each other).")
                help("Allow empee3 to find devices on your local network (Settings › Privacy & Security › Local Network).")
                help("Turn off a VPN on either device, and type the address exactly, starting with http://.")
            }
            Section {
                Text("Privacy: the page works only on your local network, only while this screen shows it as on, and only with this session's code. It uses plain HTTP, so on a shared or untrusted Wi-Fi others on the network could see what is sent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Wi-Fi Transfer")
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { transfer.stop(.backgrounded) }
        }
    }

    private var status: some View {
        let (title, detail) = statusText
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var statusText: (String, String) {
        switch transfer.state {
        case .starting: return ("Starting…", "Opening a private transfer session on this Wi-Fi.")
        case .running:
            if transfer.items.contains(where: { !$0.status.isTerminal }) {
                return ("Receiving music", "Keep both devices on this Wi-Fi until it finishes.")
            }
            if !transfer.items.isEmpty { return ("Transfer finished", "Send more from the browser, or stop when you are done.") }
            return ("Waiting for a computer", "Open the address below in a browser on the same Wi-Fi.")
        case .stopped(let reason):
            switch reason {
            case .noWifi: return ("Not connected to Wi-Fi", "Connect the phone to the same Wi-Fi as your computer, then start again.")
            case .wifiLost: return ("Wi-Fi disconnected", "Connect the phone to the same Wi-Fi as your computer, then start again.")
            case .failedToStart(let detail): return ("Could not start", "The transfer server didn't start (\(detail)). Check that Wi-Fi is on, then try again.")
            case .idleTimeout: return ("Transfer is off", "Stopped after 10 minutes without activity.")
            case .sessionExpired: return ("Transfer is off", "The session reached its time limit.")
            case .backgrounded: return ("Transfer is off", "Stopped because empee3 left the screen.")
            default: return ("Transfer is off", "Send songs and folders from a computer's browser straight to this phone.")
            }
        }
    }

    @ViewBuilder
    private func running(address: String, url: String, code: String) -> some View {
        VStack(spacing: Spacing.md) {
            if let qr = QRCode.image(url) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(Spacing.sm)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
                    .accessibilityLabel("QR code for the transfer page")
            }
            Text("Scan with your computer's camera app, or open:").font(.subheadline)
            Text(address).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
            Text("and enter the code").font(.subheadline).foregroundStyle(.secondary)
            Text(code).font(.system(size: 36, weight: .bold, design: .monospaced)).kerning(6)
                .accessibilityLabel("Pairing code \(code.map(String.init).joined(separator: " "))")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
        Button(role: .destructive) { transfer.stop() } label: { Label("Stop transfer", systemImage: "stop.circle") }
    }

    private func itemRow(_ item: TransferItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.name).lineLimit(1)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
            switch item.status {
            case .receiving:
                ProgressView(value: Double(item.receivedBytes), total: Double(max(item.sizeBytes, 1)))
            case .finalizing:
                Text("Saving…").font(.caption).foregroundStyle(.secondary)
            case .completed:
                Text("Saved").font(.caption).foregroundStyle(Color.accentColor)
            case .duplicate:
                Text("Already on phone").font(.caption).foregroundStyle(.secondary)
            case .failed:
                Text(item.message ?? "Failed").font(.caption).foregroundStyle(.red)
            case .cancelled:
                Text("Cancelled").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func help(_ text: String) -> some View { Text(text).font(.subheadline) }
}

/// A QR code image for a short text.
enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
