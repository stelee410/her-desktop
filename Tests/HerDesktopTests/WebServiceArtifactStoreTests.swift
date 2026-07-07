import XCTest
@testable import HerDesktop

final class WebServiceArtifactStoreTests: XCTestCase {
    func testLoadAllReadsRecentWebServiceArtifactManifests() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-artifact-store-\(UUID().uuidString)", isDirectory: true)
        let directory = HerWorkspacePaths.webServiceArtifactDirectory(cwd: root.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let responseFile = directory.appendingPathComponent("sample-response.json")
        let imageFile = directory.appendingPathComponent("sample-image.png")
        try Data(#"{"ok":true}"#.utf8).write(to: responseFile)
        try Data("fake-image".utf8).write(to: imageFile)
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("bad-manifest.json"))
        try manifestJSON(
            id: "sample",
            capabilityID: "agentllm.image.generate",
            responseFile: responseFile.path,
            imageFile: imageFile.path
        ).write(to: directory.appendingPathComponent("sample-manifest.json"), atomically: true, encoding: .utf8)

        let artifacts = try WebServiceArtifactStore(cwd: root.path).loadAll()

        XCTAssertEqual(artifacts.count, 1)
        let artifact = try XCTUnwrap(artifacts.first)
        XCTAssertEqual(artifact.id, "sample")
        XCTAssertEqual(artifact.capabilityID, "agentllm.image.generate")
        XCTAssertEqual(artifact.request.method, "POST")
        XCTAssertEqual(artifact.request.status, 200)
        XCTAssertEqual(artifact.responseFile, responseFile.path)
        XCTAssertEqual(artifact.primaryLocalImagePath, imageFile.path)
        XCTAssertEqual(artifact.remoteURLs, ["https://cdn.example/generated.png"])
    }

    @MainActor
    func testViewModelLoadsWebServiceArtifactsOnStartup() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-artifact-view-model-\(UUID().uuidString)", isDirectory: true)
        let directory = HerWorkspacePaths.webServiceArtifactDirectory(cwd: root.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let responseFile = directory.appendingPathComponent("response.json")
        let imageFile = directory.appendingPathComponent("image.png")
        try Data(#"{"ok":true}"#.utf8).write(to: responseFile)
        try Data("fake-image".utf8).write(to: imageFile)
        try manifestJSON(
            id: "vm-sample",
            capabilityID: "local.media.run",
            responseFile: responseFile.path,
            imageFile: imageFile.path
        ).write(to: directory.appendingPathComponent("vm-sample-manifest.json"), atomically: true, encoding: .utf8)

        let model = AppViewModel(cwd: root.path)
        model.refreshWebServiceArtifacts()

        XCTAssertEqual(model.webServiceArtifacts.map(\.id), ["vm-sample"])
    }

    @MainActor
    func testViewModelMatchesToolMessagesToArtifacts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-artifact-message-chip-\(UUID().uuidString)", isDirectory: true)
        let directory = HerWorkspacePaths.webServiceArtifactDirectory(cwd: root.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let responseFile = directory.appendingPathComponent("response.json")
        let imageFile = directory.appendingPathComponent("image.png")
        let manifestFile = directory.appendingPathComponent("chip-manifest.json")
        try Data(#"{"ok":true}"#.utf8).write(to: responseFile)
        try Data("fake-image".utf8).write(to: imageFile)
        try manifestJSON(
            id: "chip",
            capabilityID: "local.media.run",
            responseFile: responseFile.path,
            imageFile: imageFile.path
        ).write(to: manifestFile, atomically: true, encoding: .utf8)
        let model = AppViewModel(cwd: root.path)
        model.refreshWebServiceArtifacts()
        let message = ChatMessage(
            role: .tool,
            content: """
            Web Service Result
            status: 200

            Artifacts:
            artifact_manifest: \(manifestFile.path)
            response_file: \(responseFile.path)
            image_file: \(imageFile.path)
            """
        )

        XCTAssertEqual(WebServiceArtifactReferenceExtractor.manifestPaths(in: message.content), [manifestFile.path])
        XCTAssertEqual(model.webServiceArtifacts(for: message).map(\.id), ["chip"])
    }

    private func manifestJSON(
        id: String,
        capabilityID: String,
        responseFile: String,
        imageFile: String
    ) -> String {
        """
        {
          "id": "\(id)",
          "capability_id": "\(capabilityID)",
          "created_at": "2026-06-30T10:00:00Z",
          "request": {
            "method": "POST",
            "url": "https://service.example/images",
            "status": 200
          },
          "response_file": "\(responseFile)",
          "artifacts": [
            {
              "index": 0,
              "type": "remote_image",
              "url": "https://cdn.example/generated.png"
            },
            {
              "index": 1,
              "type": "image",
              "file": "\(imageFile)"
            }
          ]
        }
        """
    }
}
