import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = TranscriptionViewModel()
    @State private var isTargeted = false
    @State private var isImporterPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if viewModel.hasTranscript {
                    transcriptView
                } else {
                    dropZone
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 700, minHeight: 500)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .init(filenameExtension: "mkv")!]
        ) { result in
            if case .success(let url) = result { viewModel.selectFile(url) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Whisper Transcriber")
                    .font(.headline)
                Text("Private, on-device transcription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Model", selection: $viewModel.selectedModel) {
                ForEach(WhisperModel.catalog) { model in
                    Text(model.name).tag(model)
                }
            }
            .labelsHidden()
            .disabled(viewModel.phase.isWorking)
            .accessibilityLabel("Whisper model")
            Picker("Language", selection: $viewModel.selectedLanguage) {
                ForEach(WhisperLanguage.supported) { language in
                    Text(language.name).tag(language)
                }
            }
            .labelsHidden()
            .disabled(viewModel.phase.isWorking)
            .accessibilityLabel("Source language")
        }
        .padding()
    }

    private var dropZone: some View {
        VStack(spacing: 18) {
            Image(systemName: viewModel.phase.isWorking ? "waveform" : "arrow.down.doc")
                .font(.system(size: 44))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            Text(viewModel.phase.title)
                .font(.title2.weight(.semibold))
            if let details = viewModel.details {
                VStack(spacing: 4) {
                    Text(details.url.lastPathComponent)
                        .font(.body.weight(.medium))
                    Text("\(duration(details.durationMilliseconds)) - \(details.audioTrackDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Drop an audio or video file here, or choose one from Finder.")
                    .foregroundStyle(.secondary)
            }
            if viewModel.phase.isWorking {
                if let progress = viewModel.progress {
                    ProgressView(value: progress)
                        .frame(maxWidth: 360)
                } else {
                    ProgressView()
                }
                if let detail = viewModel.progressDetail {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if case .failed(let message) = viewModel.phase {
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 420)
            }
            if !viewModel.phase.isWorking {
                Button("Choose File...") { isImporterPresented = true }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                let url: URL?
                if let data = data as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = data as? URL
                }
                guard let url else { return }
                DispatchQueue.main.async { viewModel.selectFile(url) }
            }
            return true
        }
    }

    private var transcriptView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(viewModel.transcript) { segment in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(duration(segment.startMilliseconds))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 78, alignment: .leading)
                        Text(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding()
        }
    }

    private var footer: some View {
        HStack {
            if viewModel.hasTranscript {
                Button("Copy Text") { viewModel.copyText() }
                Button("Save VTT...") { viewModel.saveVTT() }
                Spacer()
                Button("New File") { viewModel.reset() }
            } else if viewModel.phase.isWorking {
                Spacer()
                Button("Cancel") { viewModel.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Spacer()
                Button("Transcribe") { viewModel.transcribe() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canTranscribe)
            }
        }
        .padding()
    }

    private func duration(_ milliseconds: Int64) -> String {
        WebVTTEncoder.timestamp(milliseconds)
    }
}
