import AppKit
import Foundation
import XCTest
@testable import XUI

final class XAPIClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testAuthenticatedUserSendsBearerTokenAndDecodesUser() async throws {
        let session = makeSession()
        let client = XAPIClient(baseURL: URL(string: "https://api.x.com")!, session: session)

        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/2/users/me")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.name, "user.fields")

            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"id":"1","name":"XUI User","username":"xui"}}"#.utf8)
            )
        }

        let user = try await client.authenticatedUser(accessToken: "token")

        XCTAssertEqual(user, AuthenticatedUser(id: "1", name: "XUI User", username: "xui"))
    }

    func testCreatePostSendsJSONBodyAndDecodesPost() async throws {
        let session = makeSession()
        let client = XAPIClient(baseURL: URL(string: "https://api.x.com")!, session: session)

        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/2/tweets")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(Self.bodyString(from: request), #"{"text":"hello"}"#)

            return (
                HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"id":"42","text":"hello"}}"#.utf8)
            )
        }

        let post = try await client.createPost(text: "hello", accessToken: "token")

        XCTAssertEqual(post, CreatedPost(id: "42", text: "hello"))
    }

    func testCreatePostCanAttachUploadedMedia() async throws {
        let session = makeSession()
        let client = XAPIClient(baseURL: URL(string: "https://api.x.com")!, session: session)

        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/2/tweets")
            let body = try XCTUnwrap(Self.jsonBody(from: request))
            XCTAssertEqual(body["text"] as? String, "hello")
            let media = try XCTUnwrap(body["media"] as? [String: Any])
            XCTAssertEqual(media["media_ids"] as? [String], ["123"])

            return (
                HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"id":"42","text":"hello"}}"#.utf8)
            )
        }

        let post = try await client.createPost(text: "hello", mediaIDs: ["123"], accessToken: "token")

        XCTAssertEqual(post.id, "42")
    }

    func testUploadImageSendsBase64MediaBody() async throws {
        let session = makeSession()
        let client = XAPIClient(baseURL: URL(string: "https://api.x.com")!, session: session)
        let image = AttachedImage(filename: "tiny.png", data: Data([1, 2, 3]), mediaType: "image/png")

        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/2/media/upload")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(Self.jsonBody(from: request))
            XCTAssertEqual(body["media"] as? String, "AQID")
            XCTAssertEqual(body["media_category"] as? String, "tweet_image")
            XCTAssertEqual(body["media_type"] as? String, "image/png")
            XCTAssertEqual(body["shared"] as? Bool, false)

            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"id":"123","media_key":"3_123","expires_after_secs":86400}}"#.utf8)
            )
        }

        let media = try await client.uploadImage(image, accessToken: "token")

        XCTAssertEqual(media, UploadedMedia(id: "123", mediaKey: "3_123", expiresAfterSeconds: 86400))
    }

    func testHTTPErrorUsesXErrorPayload() async throws {
        let session = makeSession()
        let client = XAPIClient(baseURL: URL(string: "https://api.x.com")!, session: session)

        StubURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"title":"Unauthorized","detail":"Bad token"}"#.utf8)
            )
        }

        do {
            _ = try await client.authenticatedUser(accessToken: "bad-token")
            XCTFail("Expected request to fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "X API request failed with 401: Unauthorized: Bad token")
        }
    }

    func testErrorBodyReadsErrorsArray() {
        let message = XAPIErrorBody.message(
            from: Data(#"{"errors":[{"title":"Forbidden","detail":"Missing tweet.write"}]}"#.utf8)
        )

        XCTAssertEqual(message, "Forbidden: Missing tweet.write")
    }

    func testDroppedImageConvertsToUploadableJPEG() throws {
        let image = NSImage(size: NSSize(width: 6400, height: 3600))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 6400, height: 3600).fill()
        image.unlockFocus()

        let attached = try AttachedImage.load(from: image, filename: "screenshot.png")

        XCTAssertEqual(attached.filename, "screenshot.png")
        XCTAssertEqual(attached.mediaType, "image/jpeg")
        XCTAssertLessThanOrEqual(attached.data.count, AttachedImage.maxImageBytes)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func bodyString(from request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8)
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer {
            stream.close()
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func jsonBody(from request: URLRequest) throws -> [String: Any]? {
        guard let body = bodyString(from: request)?.data(using: .utf8) else {
            return nil
        }
        return try JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: XAPIError.invalidResponse)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
