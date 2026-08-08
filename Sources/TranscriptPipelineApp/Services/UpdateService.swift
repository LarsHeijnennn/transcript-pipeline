import Foundation

struct AppUpdateInfo: Identifiable, Sendable {
    let version: String
    let releaseURL: URL
    let downloadURL: URL?
    let notes: String
    var id: String { version }
}

enum UpdateServiceError: LocalizedError {
    case invalidResponse
    case noReleasePublished

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The update server returned an unreadable response."
        case .noReleasePublished: "No published release is available yet."
        }
    }
}

struct UpdateService: Sendable {
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        let tagName: String
        let htmlURL: URL
        let body: String?
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body, assets
        }
    }

    func checkForUpdate(currentVersion: String? = nil) async throws -> AppUpdateInfo? {
        var request = URLRequest(url: AppConfiguration.releasesAPIURL)
        request.setValue("WhatWasSaid/1.3", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateServiceError.noReleasePublished
        }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            throw UpdateServiceError.invalidResponse
        }
        let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let current = currentVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard latest.compare(current, options: .numeric) == .orderedDescending else { return nil }
        return AppUpdateInfo(
            version: latest,
            releaseURL: release.htmlURL,
            downloadURL: release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })?.browserDownloadURL,
            notes: release.body ?? ""
        )
    }
}
