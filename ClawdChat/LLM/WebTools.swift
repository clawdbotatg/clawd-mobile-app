import Foundation
import MLXLMCommon

/// Web tools for the on-device model: keyless search (DuckDuckGo's HTML
/// endpoint) and page fetching. Inference stays local — these just give the
/// model the same internet Safari has. Results are truncated hard so they fit
/// a small model's context.
enum WebTools {

    // MARK: web_search

    struct SearchInput: Codable {
        let query: String
    }
    struct SearchResult: Codable {
        let title: String
        let url: String
        let snippet: String
    }

    static let webSearch = Tool<SearchInput, [SearchResult]>(
        name: "web_search",
        description:
            "Search the web. Returns result titles, URLs, and snippets. "
            + "Use fetch_webpage on a result URL to read more.",
        parameters: [
            .required("query", type: .string, description: "The search query")
        ]
    ) { input in
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: input.query)]
        var request = URLRequest(url: components.url!)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
            forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""
        return parseDuckDuckGo(html)
    }

    /// Pull (title, url, snippet) triples out of DuckDuckGo's HTML results.
    /// Regex over markup is crude but dependency-free; if DDG changes their
    /// markup this returns [] and the model reports the search failed.
    static func parseDuckDuckGo(_ html: String) -> [SearchResult] {
        let linkPattern =
            /<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)<\/a>/
        let snippetPattern =
            /<a[^>]*class="result__snippet"[^>]*>(.*?)<\/a>/

        let links = html.matches(of: linkPattern)
        let snippets = html.matches(of: snippetPattern)

        return links.prefix(6).enumerated().map { index, match in
            var url = String(match.1)
            // DDG wraps hrefs as //duckduckgo.com/l/?uddg=<encoded>&rut=…
            if let range = url.range(of: "uddg="),
                let decoded = String(url[range.upperBound...])
                    .components(separatedBy: "&").first?
                    .removingPercentEncoding
            {
                url = decoded
            }
            let snippet =
                index < snippets.count ? stripTags(String(snippets[index].1)) : ""
            return SearchResult(
                title: stripTags(String(match.2)),
                url: url,
                snippet: String(snippet.prefix(300))
            )
        }
    }

    // MARK: fetch_webpage

    struct FetchInput: Codable {
        let url: String
    }
    struct FetchResult: Codable {
        let text: String
    }

    static let fetchWebpage = Tool<FetchInput, FetchResult>(
        name: "fetch_webpage",
        description:
            "Fetch a web page by URL and return its readable text (truncated). "
            + "Use after web_search to read a promising result.",
        parameters: [
            .required("url", type: .string, description: "The http(s) URL to fetch")
        ]
    ) { input in
        guard let url = URL(string: input.url), url.scheme?.hasPrefix("http") == true
        else {
            return FetchResult(text: "error: invalid URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
            forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""
        return FetchResult(text: String(readableText(from: html).prefix(4000)))
    }

    /// Very small HTML → text: drop script/style blocks, strip tags,
    /// decode common entities, collapse whitespace.
    static func readableText(from html: String) -> String {
        var text = html
        for block in ["script", "style", "noscript", "svg", "header", "footer", "nav"] {
            text = text.replacing(
                try! Regex("<\(block)[^>]*>.*?</\(block)>")
                    .dotMatchesNewlines()
                    .ignoresCase(),
                with: " ")
        }
        text = stripTags(text)
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func stripTags(_ html: String) -> String {
        html
            .replacing(/<[^>]+>/, with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: wiring

    static var specs: [ToolSpec] {
        [webSearch.schema, fetchWebpage.schema]
    }

    static func dispatch(_ call: ToolCall) async -> String? {
        do {
            switch call.function.name {
            case webSearch.name:
                return try encode(await call.execute(with: webSearch))
            case fetchWebpage.name:
                return try encode(await call.execute(with: fetchWebpage))
            default:
                return nil  // not a web tool
            }
        } catch {
            return #"{"error": "\#(error.localizedDescription)"}"#
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "{}"
    }
}
