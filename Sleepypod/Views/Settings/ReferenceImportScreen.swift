import SwiftUI
import UniformTypeIdentifiers

struct ReferenceImportScreen: View {
    let model: BiometricReferencesWorkspace
    @State private var draft: ReferenceImportWorkspace
    @State private var showFiles = false
    @State private var localError: String?
    @FocusState private var editing: Bool
    init(model: BiometricReferencesWorkspace, parent: ReferenceDescriptor? = nil) {
        self.model = model
        _draft = State(initialValue: .init(side: model.side, client: model.client, parent: parent))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(draft.parent == nil ? "Map one sleeper’s source measurements to this side, then preview the exact records." : "A correction creates a new revision. Earlier revisions and frozen datasets remain unchanged.").font(.footnote).foregroundStyle(Theme.text2)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Source mapping").font(.headline)
                    ReferenceSideValue(side: draft.side)
                    TextField("Sleeper identifier", text: $draft.subject).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled().focused($editing).submitLabel(.done).onSubmit { editing = false }.accessibilityIdentifier("references.subject")
                    TextField("Source", text: $draft.source).textFieldStyle(.roundedBorder).focused($editing).submitLabel(.done).onSubmit { editing = false }.accessibilityIdentifier("references.source")
                }.disabled(draft.parent != nil || draft.busy || !model.canMutate).cardStyle()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Measurements").font(.headline)
                    Picker("Text format", selection: $draft.format) { ForEach(ReferenceTextParser.Format.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }.pickerStyle(.segmented)
                    Button("Choose CSV or JSON file", systemImage: "doc") { editing = false; showFiles = true }
                    TextEditor(text: $draft.text).font(.caption.monospaced()).frame(minHeight: 160, maxHeight: 240).scrollContentBackground(.hidden).background(Theme.background).clipShape(.rect(cornerRadius: 8)).focused($editing).accessibilityLabel("Reference records").accessibilityIdentifier("references.records")
                    if editing { Button("Done editing") { editing = false } }
                    Text("UTF-8 · up to 2 MiB and 2000 rows. Use Unix milliseconds or ISO timestamps with seconds and an explicit UTC offset. Your phone’s timezone is never assumed.").font(.caption).foregroundStyle(Theme.text2)
                    DisclosureGroup("CSV fields and metric definitions") {
                        Text("Required: recordKey, metric, value, unit, and timestampMs or startMs/endMs (or timestamp/start/end in ISO format). Optional: subjectId, aggregation, windowMs, quality, annotation.\n\nMetrics: heart_rate, breathing_rate, window_ibi_variability_v1, hrv_rmssd, hrv_sdnn, hrv_unknown, sleep_stages.\n\nSleep-stage labels require interval timestamps and unit stage. Unknown HRV definitions cannot score the Pod’s window IBI variability index. Empty CSV cells are omitted; quoted cells may contain commas and newlines.").font(.footnote).padding(.top, 8)
                    }
                    if APIBackend.current.isDemo {
                        Button(draft.parent == nil ? "Load synthetic example" : "Load corrected synthetic example") {
                            do { draft.loadSample(try .load(side: model.side, corrected: draft.parent != nil)); editing = false }
                            catch { localError = error.localizedDescription }
                        }.accessibilityIdentifier("references.sample")
                    }
                }.disabled(draft.busy || !model.canMutate).cardStyle()
                if let error = draft.error ?? localError { BiometricProfileError(error: error) }
                Button("Preview import", systemImage: "doc.text.magnifyingglass") { editing = false; localError = nil; Task { await draft.review() } }
                    .disabled(draft.busy || !model.canMutate).accessibilityIdentifier("references.preview")
                if draft.busy { ProgressView("Preparing preview…") }
                if let preview = draft.preview {
                    ReferenceSummaryCard(summary: preview)
                    if preview.rejected > 0 {
                        Toggle("I accept that the rejected rows will be omitted.", isOn: $draft.acceptRejected).disabled(!model.canMutate).accessibilityIdentifier("references.acceptRejected")
                    }
                    Button(draft.parent == nil ? "Save reviewed import" : "Save correction revision") {
                        do { let request = try draft.request(); Task { await model.commit(request) } }
                        catch { localError = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background).disabled(!model.canMutate || preview.accepted == 0 || preview.rejected > 0 && !draft.acceptRejected).accessibilityIdentifier("references.save")
                }
                ReferencePendingCard(model: model)
                if let receipt = model.receipt, receipt.summary.contentHash == draft.preview?.contentHash {
                    NavigationLink("Inspect saved reference") { ReferenceDetailScreen(model: model, initial: receipt) }.accessibilityIdentifier("references.inspectSaved")
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively).background(Theme.background).navigationTitle(draft.parent == nil ? "Import references" : "Correct reference").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("references.importContent")
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.commaSeparatedText, .json, .plainText]) { result in
                switch result {
                case .success(let url): Task { await draft.loadFile(url) }
                case .failure(let error): localError = error.localizedDescription
                }
            }
    }
}
