//
//  SecurityScope.swift
//  Helpers for using security-scoped access to a user-selected folder (granted by
//  the open panel) while mounting a volume there.
//

import Foundation

enum SecurityScope {

    /// Run `body` with security-scoped access to `url` started.
    @discardableResult
    static func withAccess<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// Async variant of ``withAccess(_:_:)``.
    @discardableResult
    static func withAccessAsync<T>(_ url: URL, _ body: () async throws -> T) async rethrows -> T {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        return try await body()
    }
}
