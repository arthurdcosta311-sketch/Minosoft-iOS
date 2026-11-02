import Foundation
import SwiftUI

struct MinecraftServer: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16
}

@MainActor
final class ServerStore: ObservableObject {
    @Published private(set) var servers: [MinecraftServer]

    private let storageKey = "minosoft.servers"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([MinecraftServer].self, from: data) {
            servers = decoded
        } else {
            servers = []
        }
    }

    func add(_ server: MinecraftServer) -> Bool {
        guard !servers.contains(where: {
            $0.host.caseInsensitiveCompare(server.host) == .orderedSame && $0.port == server.port
        }) else { return false }
        servers.append(server)
        save()
        return true
    }

    func delete(atOffsets offsets: IndexSet) {
        servers.remove(atOffsets: offsets)
        save()
    }

    func delete(_ server: MinecraftServer) {
        servers.removeAll { $0.id == server.id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

@MainActor
final class ServerPingState: ObservableObject {
    @Published private(set) var status: ServerStatus?
    @Published private(set) var errorText: String?
    @Published private(set) var isPinging = false

    func ping(_ server: MinecraftServer) async {
        guard !isPinging else { return }
        isPinging = true
        errorText = nil
        status = nil
        defer { isPinging = false }

        do {
            status = try await MinecraftPing.ping(host: server.host, port: server.port)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
