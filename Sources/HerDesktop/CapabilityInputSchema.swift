import Foundation

struct CapabilityInputField: Identifiable, Equatable {
    enum FieldType: String, Equatable {
        case string
        case number
        case integer
        case boolean
    }

    var id: String { name }
    var name: String
    var type: FieldType
    var description: String
    var required: Bool
    var enumValues: [String]
}

enum CapabilityInputSchema {
    static func fields(for capability: PluginManifest.Capability) -> [CapabilityInputField] {
        guard let schema = capability.inputSchema,
              case let .object(properties)? = schema["properties"] else {
            return []
        }
        let required = requiredFields(from: schema["required"])
        let orderedNames = required + properties.keys.sorted().filter { !required.contains($0) }
        return orderedNames.compactMap { name in
            guard let raw = properties[name],
                  case let .object(fieldSchema) = raw else {
                return nil
            }
            return CapabilityInputField(
                name: name,
                type: fieldType(from: fieldSchema["type"]),
                description: stringValue(fieldSchema["description"]) ?? "",
                required: required.contains(name),
                enumValues: enumValues(from: fieldSchema["enum"])
            )
        }
    }

    static func defaultStringValues(for fields: [CapabilityInputField]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fields.compactMap { field in
            guard field.type != .boolean else { return nil }
            return (field.name, field.enumValues.first ?? "")
        })
    }

    static func defaultBoolValues(for fields: [CapabilityInputField]) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: fields.compactMap { field in
            guard field.type == .boolean else { return nil }
            return (field.name, false)
        })
    }

    static func arguments(
        fields: [CapabilityInputField],
        stringValues: [String: String],
        boolValues: [String: Bool]
    ) -> [String: Any] {
        var arguments: [String: Any] = [:]
        for field in fields {
            switch field.type {
            case .boolean:
                arguments[field.name] = boolValues[field.name] ?? false
            case .integer:
                let text = trimmed(stringValues[field.name])
                if let value = Int(text) {
                    arguments[field.name] = value
                } else if field.required {
                    arguments[field.name] = text
                }
            case .number:
                let text = trimmed(stringValues[field.name])
                if let value = Double(text) {
                    arguments[field.name] = value
                } else if field.required {
                    arguments[field.name] = text
                }
            case .string:
                let text = trimmed(stringValues[field.name])
                if !text.isEmpty || field.required {
                    arguments[field.name] = text
                }
            }
        }
        return arguments
    }

    private static func fieldType(from value: JSONValue?) -> CapabilityInputField.FieldType {
        switch stringValue(value) {
        case "boolean":
            return .boolean
        case "integer":
            return .integer
        case "number":
            return .number
        default:
            return .string
        }
    }

    private static func requiredFields(from value: JSONValue?) -> [String] {
        guard case let .array(items)? = value else { return [] }
        return items.compactMap(stringValue)
    }

    private static func enumValues(from value: JSONValue?) -> [String] {
        guard case let .array(items)? = value else { return [] }
        return items.compactMap(stringValue)
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard case let .string(text)? = value else { return nil }
        return text
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
