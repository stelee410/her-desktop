import SwiftUI

struct PluginCapabilityChip: View {
    var text: String
    var icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(AppTheme.muted)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct CapabilityRunTarget: Identifiable {
    var pluginName: String
    var capability: PluginManifest.Capability

    var id: String { capability.id }
}

struct CapabilityRunSheet: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    var target: CapabilityRunTarget
    @State private var request = ""
    @State private var fieldValues: [String: String] = [:]
    @State private var boolValues: [String: Bool] = [:]

    var body: some View {
        let fields = CapabilityInputSchema.fields(for: target.capability)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(for: target.capability.kind))
                    .font(.title2)
                    .foregroundStyle(AppTheme.coral)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.capability.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text("\(target.pluginName) · \(target.capability.id)")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                        .textSelection(.enabled)
                    Text(adapterLabel(target.capability))
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }

            if fields.isEmpty {
                TextField("Request for this capability", text: $request, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(5...9)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(fields) { field in
                        CapabilityInputFieldView(
                            field: field,
                            stringValue: binding(for: field),
                            boolValue: boolBinding(for: field)
                        )
                    }
                }
            }

            HStack(spacing: 8) {
                Label(
                    target.capability.requiresApproval ? "Approval will be requested before execution." : "Runs immediately through the capability executor.",
                    systemImage: target.capability.requiresApproval ? "hand.raised" : "bolt"
                )
                .font(.caption)
                .foregroundStyle(target.capability.requiresApproval ? AppTheme.coral : .green)
                Spacer()
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Run") {
                    Task {
                        if fields.isEmpty {
                            await model.runCapability(target.capability, request: request)
                        } else {
                            await model.runCapability(
                                target.capability,
                                arguments: CapabilityInputSchema.arguments(
                                    fields: fields,
                                    stringValues: fieldValues,
                                    boolValues: boolValues
                                )
                            )
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
                .disabled(!canRun(fields: fields))
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(AppTheme.windowBackground)
        .onAppear {
            let fields = CapabilityInputSchema.fields(for: target.capability)
            if fieldValues.isEmpty {
                fieldValues = CapabilityInputSchema.defaultStringValues(for: fields)
            }
            if boolValues.isEmpty {
                boolValues = CapabilityInputSchema.defaultBoolValues(for: fields)
            }
        }
    }

    private func binding(for field: CapabilityInputField) -> Binding<String> {
        Binding(
            get: { fieldValues[field.name] ?? field.enumValues.first ?? "" },
            set: { fieldValues[field.name] = $0 }
        )
    }

    private func boolBinding(for field: CapabilityInputField) -> Binding<Bool> {
        Binding(
            get: { boolValues[field.name] ?? false },
            set: { boolValues[field.name] = $0 }
        )
    }

    private func canRun(fields: [CapabilityInputField]) -> Bool {
        guard !fields.isEmpty else { return true }
        return fields.allSatisfy { field in
            guard field.required, field.type != .boolean else { return true }
            return !(fieldValues[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func adapterLabel(_ capability: PluginManifest.Capability) -> String {
        let adapter = capability.adapter
        let type = adapter?.type ?? capability.kind
        if type == "webservice", let method = adapter?.method, let url = adapter?.url, !url.isEmpty {
            return "\(type) \(method) \(url)"
        }
        if type == "mcp", let methodName = adapter?.methodName, let url = adapter?.url {
            return "\(type) \(methodName) via \(url)"
        }
        if type == "command", let command = adapter?.command {
            return "\(type) \(command)"
        }
        if type == "skill", let file = adapter?.skillFile {
            return "\(type) \(file)"
        }
        return type
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "skill": return "sparkles"
        case "webservice": return "globe"
        case "mcp": return "shippingbox"
        case "command": return "terminal"
        case "native": return "macwindow"
        default: return "puzzlepiece.extension"
        }
    }
}

private struct CapabilityInputFieldView: View {
    var field: CapabilityInputField
    @Binding var stringValue: String
    @Binding var boolValue: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(field.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                if field.required {
                    Text("Required")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.coral)
                }
                Spacer()
            }

            if !field.description.isEmpty {
                Text(field.description)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
            }

            inputControl
        }
    }

    @ViewBuilder
    private var inputControl: some View {
        if field.type == .boolean {
            Toggle(field.name, isOn: $boolValue)
                .labelsHidden()
        } else if !field.enumValues.isEmpty {
            Picker(field.name, selection: $stringValue) {
                ForEach(field.enumValues, id: \.self) { value in
                    Text(value).tag(value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(placeholder, text: $stringValue, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(field.name == "prompt" || field.name == "request" ? 3...7 : 1...3)
        }
    }

    private var placeholder: String {
        switch field.type {
        case .integer:
            return "0"
        case .number:
            return "0.0"
        default:
            return field.name
        }
    }
}
