import SwiftUI

struct RawSourceInspectionScreen: View {
    let source: InspectedRawSource
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(source.inspection.sourceName).font(.headline).textSelection(.enabled)
                    Text(source.availability == "unavailable" ? "Source unavailable" : "Inspected; requires re-verification").foregroundStyle(Theme.text2)
                    Text("Inspection records metadata. It does not retain archive bytes or establish continuous coverage.").font(.footnote).foregroundStyle(Theme.text2)
                    BiometricProfileDate(title: "Inspected", milliseconds: source.inspectedAtMs)
                    if let unavailable = source.unavailableAtMs { BiometricProfileDate(title: "Unavailable since", milliseconds: unavailable) }
                    BiometricProfileIdentity(title: "Source identity", value: source.id)
                    BiometricProfileIdentity(title: "Artifact hash", value: source.inspection.artifact.sha256)
                    BiometricProfileValue("Compressed bytes", value: source.inspection.artifact.compressedBytes.formatted())
                    BiometricProfileValue("Expanded bytes", value: source.inspection.artifact.expandedBytes.formatted())
                }.cardStyle()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recorded inventory").font(.headline).accessibilityIdentifier("waveforms.inventory")
                    BiometricProfileValue("Ordered waveforms", value: source.inspection.inventory.orderedWaveformAvailable ? "Available for retention review" : "Unavailable")
                    if let first = source.inspection.inventory.firstEventMs { BiometricProfileValue("First event · UTC", value: ReferenceLabels.utc(first)) }
                    if let last = source.inspection.inventory.lastEventMs { BiometricProfileValue("Last event · UTC", value: ReferenceLabels.utc(last)) }
                    BiometricProfileValue("Decoded records", value: source.inspection.inventory.decodedRecords.formatted())
                    BiometricProfileValue("Piezo records", value: source.inspection.inventory.piezoRecords.formatted())
                    BiometricProfileValue("Pump records", value: source.inspection.inventory.pumpRecords.formatted())
                    BiometricProfileValue("Usable dual frames", value: source.inspection.inventory.usableDualFrames.formatted())
                    BiometricProfileValue("Empty-channel frames", value: source.inspection.inventory.emptyChannelFrames.formatted())
                    BiometricProfileValue("Oversize-channel frames", value: source.inspection.inventory.oversizeChannelFrames.formatted())
                    BiometricProfileValue("Invalid timestamps", value: source.inspection.inventory.invalidTimestamps.formatted())
                    BiometricProfileValue("Timestamp reversals", value: source.inspection.inventory.timestampReversals.formatted())
                    BiometricProfileValue("Duplicate timestamps", value: source.inspection.inventory.duplicateTimestamps.formatted())
                }.cardStyle()
                RawChannelCard(title: "Left channel", channel: source.inspection.inventory.channels.left1)
                RawChannelCard(title: "Right channel", channel: source.inspection.inventory.channels.right1)
                ForEach(source.inspection.inventory.limitations, id: \.self) { Text($0).font(.footnote).foregroundStyle(Theme.text2) }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Archive inspection").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("waveforms.inspectionContent")
    }
}
struct RawChannelCard: View {
    let title: String
    let channel: InspectedRawInventory.Channel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            BiometricProfileValue("Samples", value: channel.samples.formatted())
            BiometricProfileValue("Lost markers", value: channel.lostMarkers.formatted())
            BiometricProfileValue("Truncated tail bytes", value: channel.truncatedTailBytes.formatted())
        }.cardStyle()
    }
}
