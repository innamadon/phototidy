import SwiftUI

struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var cleared = false
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $model.appearance) {
                        Text("Match iPhone").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                } footer: {
                    Text("Light is cream paper; Dark is midnight navy.")
                }

                Section {
                    Picker("Look through", selection: $model.range) {
                        ForEach(ScanRange.allCases) { range in
                            Text(range.label).tag(range)
                        }
                    }
                } header: {
                    Text("Scans")
                } footer: {
                    Text("Used by the Similar, Blurry, Duplicates and Receipts scans. Start small; the first scan of a range is the slow one.")
                }

                Section {
                    Picker("Shots taken within", selection: $model.gap) {
                        ForEach(ShotGap.allCases) { gap in
                            Text(gap.label).tag(gap)
                        }
                    }
                    Slider(value: $model.strictness, in: 0...1) {
                        Text("How alike")
                    } minimumValueLabel: {
                        Text("Loose").font(.caption)
                    } maximumValueLabel: {
                        Text("Strict").font(.caption)
                    }
                    Toggle("Include screenshots", isOn: $model.includeScreenshots)
                } header: {
                    Text("Similar photos")
                } footer: {
                    Text("Groups mixing different scenes? Slide toward Strict. Obvious look-alikes missed? Slide toward Loose. Changes apply to the next scan.")
                }

                Section {
                    Toggle("Keep photos with people", isOn: $model.keepBlurryPeople)
                } header: {
                    Text("Blurry photos")
                } footer: {
                    Text("When on, blurry shots with a face or a person in them are never suggested.")
                }

                Section {
                    TextField("https://mydesktop.tail1234.ts.net", text: $model.filerAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: model.filerAddress) { _, _ in
                            testResult = nil
                        }
                    Button(testing ? "Checking…" : "Test connection") {
                        testing = true
                        Task {
                            testResult = await model.testFiler()
                            testing = false
                        }
                    }
                    .disabled(testing || model.filerAddress.isEmpty)
                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(Tidy.muted)
                    }
                } header: {
                    Text("Receipt filer")
                } footer: {
                    Text("The address your iPhone uses to open the receipt filer. It's shown in the filer's window on your PC when it starts. Tailscale needs to be on on this iPhone when you file receipts.")
                }

                Section {
                    Toggle("Move to an album instead", isOn: $model.moveToAlbum)
                } header: {
                    Text("When you remove something")
                } footer: {
                    Text(model.moveToAlbum
                         ? "Removed items go to the “Photo Tidy – To Review” album and stay in your library until you delete them in Photos. Needs full photo access."
                         : "Removed items go to Recently Deleted, where iOS keeps them for 30 days.")
                }

                Section {
                    Button(cleared ? "Saved scan data cleared" : "Clear saved scan data") {
                        model.clearSavedScanData()
                        cleared = true
                    }
                    .disabled(cleared || model.isBusy)
                } footer: {
                    Text("Photo Tidy remembers what it measured so later scans are much faster. Clearing this never touches your photos.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tidy.paper.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Tidy.bronze)
        .onDisappear {
            model.saveSettings()
        }
    }
}
