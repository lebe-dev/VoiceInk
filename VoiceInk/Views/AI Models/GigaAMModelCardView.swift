import SwiftUI
import AppKit

struct GigaAMModelCardView: View {
    let model: GigaAMModel
    @ObservedObject var gigaAMModelManager: GigaAMModelManager
    @ObservedObject var transcriptionModelManager: TranscriptionModelManager

    init(model: GigaAMModel, gigaAMModelManager: GigaAMModelManager, transcriptionModelManager: TranscriptionModelManager) {
        self.model = model
        _gigaAMModelManager = ObservedObject(wrappedValue: gigaAMModelManager)
        _transcriptionModelManager = ObservedObject(wrappedValue: transcriptionModelManager)
    }

    var isCurrent: Bool {
        transcriptionModelManager.currentTranscriptionModel?.name == model.name
    }

    var isDownloaded: Bool {
        gigaAMModelManager.isGigaAMModelDownloaded(model)
    }

    var isDownloading: Bool {
        gigaAMModelManager.isGigaAMModelDownloading(model)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                headerSection
                metadataSection
                descriptionSection
                progressSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionSection
        }
        .padding(16)
        .background(CardBackground(isSelected: isCurrent, useAccentGradientWhenSelected: isCurrent))
    }

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(.labelColor))

            Spacer()
        }
    }

    private var metadataSection: some View {
        HStack(spacing: 12) {
            Label(model.language, systemImage: "globe")
            Label(model.size, systemImage: "internaldrive")
            HStack(spacing: 3) {
                Text("Speed")
                progressDotsWithNumber(value: model.speed * 10)
            }
            .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 3) {
                Text("Accuracy")
                progressDotsWithNumber(value: model.accuracy * 10)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 11))
        .foregroundColor(Color(.secondaryLabelColor))
        .lineLimit(1)
    }

    private var descriptionSection: some View {
        Text(model.description)
            .font(.system(size: 11))
            .foregroundColor(Color(.secondaryLabelColor))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    private var progressSection: some View {
        Group {
            if let status = gigaAMModelManager.downloadStatus(for: model) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(status.message)
                            .lineLimit(1)

                        Spacer()

                        Text("\(Int(status.fractionCompleted * 100))%")
                            .fontDesign(.monospaced)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(.secondaryLabelColor))

                    ProgressView(value: status.fractionCompleted)
                        .progressViewStyle(LinearProgressViewStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .animation(.smooth, value: status.fractionCompleted)
            }
        }
    }

    private var actionSection: some View {
        HStack(spacing: 8) {
            if isCurrent {
                Text("Default Model")
                    .font(.system(size: 12))
                    .foregroundColor(Color(.secondaryLabelColor))
            } else if isDownloaded {
                Button(action: {
                    Task {
                        transcriptionModelManager.setDefaultTranscriptionModel(model)
                    }
                }) {
                    Text("Set as Default")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if isDownloading {
                Button(action: {
                    gigaAMModelManager.cancelDownload(for: model)
                }) {
                    Text("Cancel")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button(action: {
                    Task {
                        try? await gigaAMModelManager.downloadGigaAMModel(model)
                    }
                }) {
                    HStack(spacing: 4) {
                        Text("Download")
                        Image(systemName: "arrow.down.circle")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }

            if isDownloaded {
                Menu {
                    Button(action: {
                        gigaAMModelManager.deleteGigaAMModel(model)
                    }) {
                        Label("Delete Model", systemImage: "trash")
                    }

                    Button {
                        gigaAMModelManager.showGigaAMModelInFinder(model)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }

                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20, height: 20)
            }
        }
    }
}
