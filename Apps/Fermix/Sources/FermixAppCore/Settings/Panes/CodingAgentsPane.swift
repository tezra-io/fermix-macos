import SwiftUI

/// Installation and sign-in facts come from the daemon's bounded detection.
struct CodingAgentAvailability {
    let detection: ManagementDetection?

    var vendors: [ManagementHarnessVendor] { detection?.vendors ?? [] }
    var hasFacts: Bool { detection?.vendors != nil }
    var guidance: String? { detection?.guidance }

    func canSelect(_ vendor: String) -> Bool {
        vendor.isEmpty || vendors.contains { $0.vendor == vendor && $0.installed }
    }

    func canEditConsent(currentlyEnabled: Bool) -> Bool {
        currentlyEnabled || vendors.contains { $0.installed }
    }

    func status(for vendor: ManagementHarnessVendor) -> String {
        guard vendor.installed else { return ProductStrings[.codingNotInstalled] }

        let auth: String
        switch vendor.auth {
        case .authenticated: auth = ProductStrings[.codingAuthenticated]
        case .unverified: auth = ProductStrings[.codingAuthUnverified]
        case .absent: auth = ProductStrings[.codingAuthAbsent]
        }
        return ProductStrings.middot(vendor.version ?? ProductStrings[.codingInstalled], auth)
    }
}

struct CodingAgentsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPaneForm(title: SettingsPane.codingAgents.title) {
            if model.requiresNewerEngine {
                NewerEngineSection(sentence: model.newerEngineSentence)
            } else {
                sections
                detectionStatus
            }
        }
        .task { await model.refreshDetections([.harnessVendors]) }
    }

    private var availability: CodingAgentAvailability {
        CodingAgentAvailability(detection: model.detections.value?.result(for: .harnessVendors))
    }

    private var sections: some View {
        ForEach(model.sections(for: .codingAgents), id: \.id) { section in
            DescriptorSection(model: model, section: section) { row in
                specialised(row, section: section.id)
            }
        }
    }

    private func specialised(_ row: ManagementSettingRow, section: String) -> AnyView? {
        guard !row.readOnly else { return nil }

        switch row.key {
        case SettingsBinding.codingConsent:
            let enabled = DescriptorValue.flag(model.value(of: row, in: section))
            return AnyView(DescriptorRow(model: model, section: section, row: row)
                .disabled(!availability.canEditConsent(currentlyEnabled: enabled)))
        case SettingsBinding.codingPreference:
            return AnyView(CodingAgentChoiceRow(
                row: row, section: section, model: model, availability: availability
            ))
        default:
            return nil
        }
    }

    private var detectionStatus: some View {
        Section {
            if model.detections.isLoading {
                ProgressView().controlSize(.small)
            }
            if let sentence = detectionSentence {
                Text(sentence)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(ProductStrings[.codingCheckAgain]) {
                Task { await model.refreshDetections([.harnessVendors]) }
            }
            .disabled(model.detections.isLoading)
        }
    }

    private var detectionSentence: String? {
        if case .unavailable(let sentence) = model.detections { return sentence }
        if model.detections.isLoading { return nil }
        if !availability.hasFacts { return ProductStrings[.codingDetectionUnavailable] }

        return availability.guidance
    }
}

/// The preferred value is preserved when its tool disappears. The menu keeps
/// that option visible with its status but refuses a new unavailable selection.
private struct CodingAgentChoiceRow: View {
    let row: ManagementSettingRow
    let section: String
    @ObservedObject var model: SettingsModel
    let availability: CodingAgentAvailability

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            Picker(row.label, selection: selection) {
                if !row.options.contains(where: { $0.value == selected }) {
                    Text(selected.isEmpty ? ProductStrings[.settingsChoiceNotSet] : selected)
                        .tag(selected).disabled(true)
                }
                ForEach(row.options, id: \.value) { option in
                    Text(label(for: option)).tag(option.value)
                        .disabled(option.disabled || !availability.canSelect(option.value))
                }
            }
            if let footer = row.footer {
                Text(footer).fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
            }
            if let sentence = model.message(for: SettingsDraftKey(section: section, key: row.key)) {
                Text(sentence).fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
            }
        }
        .disabled(model.writesBlocked)
    }

    private var selected: String { DescriptorValue.text(model.value(of: row, in: section)) }

    private func label(for option: ManagementSettingOption) -> String {
        guard !option.value.isEmpty else { return option.label }
        let vendor = availability.vendors.first { $0.vendor == option.value }
        let status = vendor.map { availability.status(for: $0) } ?? ProductStrings[.permissionsProfileUnknown]

        return ProductStrings.middot(option.label, status)
    }

    private var selection: Binding<String> {
        Binding(get: { selected }, set: { value in
            guard !model.writesBlocked, availability.canSelect(value),
                  row.options.contains(where: { $0.value == value && !$0.disabled }) else { return }

            Task { await model.apply(section: section, key: row.key, value: .text(value)) }
        })
    }
}
