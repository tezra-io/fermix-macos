import Foundation

/// The typed projection Home renders: readiness, health, daemon, provider,
/// channels, memory, jobs, agents, realtime, and capability counts, exactly as
/// `overview.get` publishes them.
public struct ManagementOverview: Decodable, Equatable, Sendable {
    public let generatedAt: String?
    public let readiness: Readiness
    public let health: Health
    public let daemon: Daemon
    public let provider: Provider
    public let channels: [Channel]
    public let memory: Memory
    public let jobs: Jobs
    public let agents: Agents
    public let realtime: Realtime
    public let capabilities: CapabilityCounts

    private enum CodingKeys: String, CodingKey {
        case readiness, health, daemon, provider, channels, memory, jobs, agents, realtime
        case capabilities
        case generatedAt = "generated_at"
    }

    public struct Readiness: Decodable, Equatable, Sendable {
        public let status: String?
        public let failureCount: Int

        private enum CodingKeys: String, CodingKey {
            case status
            case failureCount = "failure_count"
        }
    }

    public struct ProviderHealth: Decodable, Equatable, Sendable {
        public let name: String?
        public let status: String?
        public let authMode: String?
        public let primary: Bool

        private enum CodingKeys: String, CodingKey {
            case name, status, primary
            case authMode = "auth_mode"
        }
    }

    public struct Health: Decodable, Equatable, Sendable {
        public let status: String?
        public let restartRequired: Bool
        public let providers: [ProviderHealth]
        /// Which configuration sections a restart would apply, added by
        /// protocol v2 on a method whose own minimum is 1.
        ///
        /// Absent on a daemon one release behind, which is exactly the state
        /// `pendingEngineRestart` polls through, so it is optional and its
        /// absent rendering is an empty list: the plain restart sentence with
        /// no reason list (M34 §7.1).
        public let restartReasons: [String]?

        /// The sections a restart would apply, or none where the daemon
        /// publishes none.
        public var restartReasonSections: [String] { restartReasons ?? [] }

        private enum CodingKeys: String, CodingKey {
            case status, providers
            case restartRequired = "restart_required"
            case restartReasons = "restart_reasons"
        }
    }

    public struct Daemon: Decodable, Equatable, Sendable {
        public let status: String?
        public let version: String?
        public let uptimeMs: Int?
        public let pid: String?

        private enum CodingKeys: String, CodingKey {
            case status, version, pid
            case uptimeMs = "uptime_ms"
        }
    }

    public struct Provider: Decodable, Equatable, Sendable {
        public let active: String?
        public let model: String?
        public let authMode: String?
        public let reasoningEffort: String?

        private enum CodingKeys: String, CodingKey {
            case active, model
            case authMode = "auth_mode"
            case reasoningEffort = "reasoning_effort"
        }
    }

    public struct Channel: Decodable, Equatable, Sendable {
        public let name: String?
        public let status: String?
        public let enabled: Bool
        public let mode: String?
        public let processAlive: Bool?

        private enum CodingKeys: String, CodingKey {
            case name, status, enabled, mode
            case processAlive = "process_alive"
        }
    }

    public struct Memory: Decodable, Equatable, Sendable {
        public let repo: String?
        public let conversationStore: String?
        public let store: String?

        private enum CodingKeys: String, CodingKey {
            case repo, store
            case conversationStore = "conversation_store"
        }
    }

    public struct ScheduledJob: Decodable, Equatable, Sendable {
        public let id: String?
        public let name: String?
        public let nextRunAt: String?
        public let state: String?

        private enum CodingKeys: String, CodingKey {
            case id, name, state
            case nextRunAt = "next_run_at"
        }
    }

    public struct Jobs: Decodable, Equatable, Sendable {
        public let scheduled: Int
        public let running: Int
        public let paused: Int
        public let failedRecent: Int
        public let next: ScheduledJob?
        public let status: String?

        private enum CodingKeys: String, CodingKey {
            case scheduled, running, paused, next, status
            case failedRecent = "failed_recent"
        }
    }

    public struct MainAgent: Decodable, Equatable, Sendable {
        public let health: String?
        public let activity: String?
        public let status: String?
        public let activeConversations: Int
        public let pendingConversations: Int

        private enum CodingKeys: String, CodingKey {
            case health, activity, status
            case activeConversations = "active_conversations"
            case pendingConversations = "pending_conversations"
        }
    }

    public struct Agents: Decodable, Equatable, Sendable {
        public let main: MainAgent
        public let skillWorkers: Int
        public let runningSkillWorkers: Int

        private enum CodingKeys: String, CodingKey {
            case main
            case skillWorkers = "skill_workers"
            case runningSkillWorkers = "running_skill_workers"
        }
    }

    public struct Realtime: Decodable, Equatable, Sendable {
        public let enabled: Bool
        public let status: String?
        public let provider: String?
        public let model: String?
        public let socketAlive: Bool?
        public let activeSessions: Int
        public let activeClients: Int
        public let companionConnected: Bool

        private enum CodingKeys: String, CodingKey {
            case enabled, status, provider, model
            case socketAlive = "socket_alive"
            case activeSessions = "active_sessions"
            case activeClients = "active_clients"
            case companionConnected = "companion_connected"
        }
    }

    public struct CapabilityCounts: Decodable, Equatable, Sendable {
        public let builtin: Int
        public let skill: Int
        public let mcp: Int
        public let total: Int
    }
}
