// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Aayan Agarwal

import Foundation

final class Persistence {
    private let url: URL
    private let queue = DispatchQueue(label: "com.aayanagarwal.mix.persist")
    private var store: SavedStore

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Mix", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("routes.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(SavedStore.self, from: data) {
            store = decoded
        } else {
            store = .empty
        }
    }

    var snapshot: SavedStore {
        queue.sync { store }
    }

    func route(for bundleID: String) -> SavedRoute? {
        queue.sync { store.apps[bundleID] }
    }

    func upsert(_ route: SavedRoute, for bundleID: String) {
        queue.sync {
            if route.isManaged {
                store.apps[bundleID] = route
            } else {
                store.apps.removeValue(forKey: bundleID)
            }
            persistLocked()
        }
    }

    func remove(_ bundleID: String) {
        queue.sync {
            store.apps.removeValue(forKey: bundleID)
            persistLocked()
        }
    }

    func markPermissionPrompted() {
        queue.sync {
            store.didRequestAudioPermission = true
            persistLocked()
        }
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}