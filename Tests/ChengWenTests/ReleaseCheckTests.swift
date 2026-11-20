import XCTest
@testable import ChengWen

final class ReleaseCheckTests: XCTestCase {
    private func release(_ tag: String = "v0.9.10") -> [String: Any] {
        let version = String(tag.dropFirst())
        let base = "https://github.com/ixiehao/chengwen/releases"
        return [
            "tag_name": tag, "draft": false, "prerelease": false,
            "html_url": "\(base)/tag/\(tag)",
            "assets": ["arm64", "x86_64"].flatMap { cpu in
                let name = "chengwen-\(version)-\(cpu).dmg"
                return [name, name + ".sha256"].map { filename in
                    ["name": filename, "state": "uploaded", "size": 100,
                     "browser_download_url": "\(base)/download/\(tag)/\(filename)"] as [String: Any]
                }
            }
        ]
    }

    private func check(_ body: [String: Any], installed: String = "0.9.9") async -> ReleaseCheck {
        await ReleaseCheck.latest(installedVersion: installed) { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (try JSONSerialization.data(withJSONObject: body), response)
        }
    }

    func testLatestReleaseUsesNumericVersionsAndOfficialPage() async {
        let result = await ReleaseCheck.latest(installedVersion: "0.9.9") { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.absoluteString, "https://api.github.com/repos/ixiehao/chengwen/releases/latest")
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            let body = try JSONSerialization.data(withJSONObject: self.release())
            return (body, response)
        }
        XCTAssertEqual(result, .available(
            version: "0.9.10", page: URL(string: "https://github.com/ixiehao/chengwen/releases/tag/v0.9.10")!
        ))
    }

    func testLatestReleaseRequiresOfficialPageAndAllInstallerAttachments() async {
        var foreignPage = release()
        foreignPage["html_url"] = "https://github.com/elsewhere/chengwen/releases/tag/v0.9.10"
        let pageResult = await check(foreignPage)
        XCTAssertEqual(pageResult, .unavailable)
        var foreignAsset = release()
        var assets = foreignAsset["assets"] as! [[String: Any]]
        assets[0]["browser_download_url"] = "https://example.invalid/installer.dmg"
        foreignAsset["assets"] = assets
        let assetResult = await check(foreignAsset)
        XCTAssertEqual(assetResult, .unavailable)
        var missingChecksum = release()
        missingChecksum["assets"] = Array((missingChecksum["assets"] as! [[String: Any]]).dropLast())
        let incompleteResult = await check(missingChecksum)
        XCTAssertEqual(incompleteResult, .unavailable)
    }

    func testCurrentAndOlderReleasesDoNotOfferDowngrade() async {
        for version in ["0.9.10", "0.10.0"] {
            let result = await check(release(), installed: version)
            XCTAssertEqual(result, .upToDate)
        }
    }

    func testOfflineAndUnexpectedRedirectFailWithoutOfferingDownload() async {
        let offline = await ReleaseCheck.latest(installedVersion: "0.9.5") { _ in
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(offline, .unavailable)
        let redirected = await ReleaseCheck.latest(installedVersion: "0.9.5") { _ in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: URL(string: "https://api.github.com/repos/other/chengwen/releases/latest")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (try JSONSerialization.data(withJSONObject: self.release()), response)
        }
        XCTAssertEqual(redirected, .unavailable)
    }

    func testMissingReleaseAndPreviewReportNoStableRelease() async {
        let noRelease = await ReleaseCheck.latest(installedVersion: "0.9.5") { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: 404, httpVersion: nil, headerFields: nil
            ))
            return (Data(), response)
        }
        XCTAssertEqual(noRelease, .noPublicRelease)

        for (tag, markedPrerelease) in [("v0.9.6", true), ("v0.9.6-preview.1", false)] {
            let preview = await ReleaseCheck.latest(installedVersion: "0.9.5") { request in
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil
                ))
                let body = try JSONSerialization.data(withJSONObject: [
                    "tag_name": tag, "draft": false, "prerelease": markedPrerelease
                ])
                return (body, response)
            }
            XCTAssertEqual(preview, .noPublicRelease)
        }
    }

    func testRetryAfterRateLimit() async {
        let before = Date()
        let result = await ReleaseCheck.latest(installedVersion: "0.9.5") { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: 403, httpVersion: nil, headerFields: ["Retry-After": "120"]
            ))
            return (Data(), response)
        }
        guard case let .rateLimited(until) = result else { return XCTFail("Expected rate limiting") }
        XCTAssertGreaterThanOrEqual(until.timeIntervalSince(before), 120)
    }
}
