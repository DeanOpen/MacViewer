import SwiftUI

struct MacSharingDisplayPicker: View {
    @ObservedObject var hosting: MacHostingModel
    var showsExplanation = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Share display", selection: Binding(get: { hosting.selectedDisplayKey }, set: { hosting.selectDisplay($0) })) {
                Text("All displays").tag(MacDisplayLayout.allDisplaysKey)
                if hosting.selectedDisplayKey != MacDisplayLayout.allDisplaysKey,
                   !hosting.displays.contains(where: { $0.key == hosting.selectedDisplayKey }) {
                    Text("Selected display disconnected").tag(hosting.selectedDisplayKey).disabled(true)
                }
                ForEach(Array(hosting.displays.enumerated()), id: \.element.id) { index, display in
                    Text(LF(display.isMain ? "Display %ld · %@ (Main)" : "Display %ld · %@", index + 1, display.name))
                        .tag(display.key)
                }
            }
            .pickerStyle(.menu)
            .disabled(hosting.isApproving || hosting.displays.isEmpty || hosting.isEndingViewer)
            if showsExplanation {
                Text(LocalizedStringKey(hosting.selectedDisplayKey == MacDisplayLayout.allDisplaysKey
                     ? "On Windows, use UltraViewer’s monitor menu to view one display or all displays."
                     : "Only this display is shared. You can change it during the connection."))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
