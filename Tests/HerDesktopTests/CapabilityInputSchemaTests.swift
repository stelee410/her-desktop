import XCTest
@testable import HerDesktop

final class CapabilityInputSchemaTests: XCTestCase {
    func testFieldsParseObjectPropertiesRequiredAndEnums() {
        let capability = PluginManifest.Capability(
            id: "local.image.run",
            title: "Generate",
            kind: "webservice",
            invocation: "local.image.run",
            requiresApproval: true,
            inputSchema: [
                "type": .string("object"),
                "required": .array([.string("prompt")]),
                "properties": .object([
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string("Visual prompt")
                    ]),
                    "size": .object([
                        "type": .string("string"),
                        "enum": .array([.string("1024x1024"), .string("1536x1024")])
                    ]),
                    "private": .object([
                        "type": .string("boolean")
                    ])
                ])
            ]
        )

        let fields = CapabilityInputSchema.fields(for: capability)

        XCTAssertEqual(fields.map(\.name), ["prompt", "private", "size"])
        XCTAssertEqual(fields.first?.description, "Visual prompt")
        XCTAssertEqual(fields.first?.required, true)
        XCTAssertEqual(fields.first { $0.name == "private" }?.type, .boolean)
        XCTAssertEqual(fields.first { $0.name == "size" }?.enumValues, ["1024x1024", "1536x1024"])
        XCTAssertEqual(CapabilityInputSchema.defaultStringValues(for: fields)["size"], "1024x1024")
        XCTAssertEqual(CapabilityInputSchema.defaultBoolValues(for: fields)["private"], false)
    }

    func testArgumentsCoerceSupportedFieldTypes() {
        let fields = [
            CapabilityInputField(name: "prompt", type: .string, description: "", required: true, enumValues: []),
            CapabilityInputField(name: "count", type: .integer, description: "", required: false, enumValues: []),
            CapabilityInputField(name: "temperature", type: .number, description: "", required: false, enumValues: []),
            CapabilityInputField(name: "enabled", type: .boolean, description: "", required: false, enumValues: [])
        ]

        let arguments = CapabilityInputSchema.arguments(
            fields: fields,
            stringValues: [
                "prompt": " coral UI ",
                "count": "3",
                "temperature": "0.7"
            ],
            boolValues: ["enabled": true]
        )

        XCTAssertEqual(arguments["prompt"] as? String, "coral UI")
        XCTAssertEqual(arguments["count"] as? Int, 3)
        XCTAssertEqual(arguments["temperature"] as? Double, 0.7)
        XCTAssertEqual(arguments["enabled"] as? Bool, true)
    }
}
