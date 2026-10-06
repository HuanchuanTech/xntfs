import SwiftUI

struct ExtensionEnablementInstructions: View {
    var majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Open System Settings > General > Login Items & Extensions, then scroll down to Extensions.")
            if majorVersion >= 26 {
                Text("Select **By Category**, not By App. Open File System Extensions and turn on ntfs3g.")
            } else {
                Text("Open File System Extension and turn on ntfs3g.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
