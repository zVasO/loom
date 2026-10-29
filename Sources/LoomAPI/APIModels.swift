import LoomCore
import Foundation

// The parameters and results of every method — the shapes a client types
// against. Session references are optional: a session token means "mine",
// a global token must say which.

/// A session as the API shows it. `state` is the session state's raw value
/// (CONTEXT.md: working, needs_input, idle, …); dates are ISO 8601.
public struct APISession: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var state: String
    public var projectID: String?
    public var branch: String?
    public var worktreePath: String?
    public var badges: [String]
    public var createdAt: String

    public init(id: String, title: String, state: String, projectID: String? = nil,
                branch: String? = nil, worktreePath: String? = nil, badges: [String],
                createdAt: String) {
        self.id = id
        self.title = title
        self.state = state
        self.projectID = projectID
        self.branch = branch
        self.worktreePath = worktreePath
        self.badges = badges
        self.createdAt = createdAt
    }
}

/// `session.get`: which session — omitted under a session token.
public struct APISessionRef: Codable, Equatable, Sendable {
    public var sessionId: String?
    public init(sessionId: String? = nil) { self.sessionId = sessionId }
}

/// `sessions.list`: archived sessions stay out unless asked for.
public struct APISessionsListParams: Codable, Equatable, Sendable {
    public var includeArchived: Bool?
    public init(includeArchived: Bool? = nil) { self.includeArchived = includeArchived }
}

public struct APISessionsListResult: Codable, Equatable, Sendable {
    public var sessions: [APISession]
    public init(sessions: [APISession]) { self.sessions = sessions }
}

/// `session.setTitle`.
public struct APISetTitleParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var title: String
    public init(sessionId: String? = nil, title: String) {
        self.sessionId = sessionId
        self.title = title
    }
}

/// `session.setBadges`: the whole list, in order; empty clears.
public struct APISetBadgesParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var badges: [String]
    public init(sessionId: String? = nil, badges: [String]) {
        self.sessionId = sessionId
        self.badges = badges
    }
}

/// One entry of the badge catalog.
public struct APIBadge: Codable, Equatable, Sendable {
    public var name: String
    /// `#RRGGBB`.
    public var colorHex: String
    public init(name: String, colorHex: String) {
        self.name = name
        self.colorHex = colorHex
    }

    /// The only color shape the catalog accepts.
    public static func isValidColor(_ hex: String) -> Bool {
        guard hex.count == 7, hex.hasPrefix("#") else { return false }
        return hex.dropFirst().allSatisfy(\.isHexDigit)
    }
}

public struct APIBadgeListResult: Codable, Equatable, Sendable {
    public var badges: [APIBadge]
    public init(badges: [APIBadge]) { self.badges = badges }
}

/// `badge.create`: the color is optional — the catalog's muted default otherwise.
public struct APICreateBadgeParams: Codable, Equatable, Sendable {
    public var name: String
    public var colorHex: String?
    public init(name: String, colorHex: String? = nil) {
        self.name = name
        self.colorHex = colorHex
    }
}

/// `loom.version`.
public struct APIVersion: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var app: String
    public init(protocolVersion: Int, app: String) {
        self.protocolVersion = protocolVersion
        self.app = app
    }
}

// MARK: - Workflow runs (ADR-0018)

/// One step of the run, as `workflow.get` shows it.
public struct APIWorkflowStep: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// start, context, agent, condition, loop, artifact.
    public var type: String
    /// pending, running, waitingOnUser, done, failed, skipped.
    public var status: String
    public var pass: Int
    public var expert: String?
    /// headless or visible, for an agent.
    public var mode: String?
    /// A visible step's Loom session.
    public var sessionId: String?
    public var hasAnswer: Bool
    /// Whether loom_workflow_step_ask can reach it now.
    public var askable: Bool
    public var reruns: Int
    public var error: String?

    public init(id: String, title: String, type: String, status: String, pass: Int, expert: String? = nil,
                mode: String? = nil, sessionId: String? = nil, hasAnswer: Bool, askable: Bool, reruns: Int,
                error: String? = nil) {
        self.id = id
        self.title = title
        self.type = type
        self.status = status
        self.pass = pass
        self.expert = expert
        self.mode = mode
        self.sessionId = sessionId
        self.hasAnswer = hasAnswer
        self.askable = askable
        self.reruns = reruns
        self.error = error
    }
}

/// `workflow.get`.
public struct APIWorkflowState: Codable, Equatable, Sendable {
    public var runId: String
    public var workflow: String
    public var subject: String
    /// running, succeeded, failed, cancelled, interrupted.
    public var status: String
    /// The run waits for the orchestrator (a checkpoint) — loom_workflow_proceed lets it go.
    public var waitingForYou: Bool
    public var interventionsLeft: Int
    public var rerunsPerStep: Int
    public var costUSD: Double
    public var steps: [APIWorkflowStep]

    public init(runId: String, workflow: String, subject: String, status: String, waitingForYou: Bool,
                interventionsLeft: Int, rerunsPerStep: Int, costUSD: Double, steps: [APIWorkflowStep]) {
        self.runId = runId
        self.workflow = workflow
        self.subject = subject
        self.status = status
        self.waitingForYou = waitingForYou
        self.interventionsLeft = interventionsLeft
        self.rerunsPerStep = rerunsPerStep
        self.costUSD = costUSD
        self.steps = steps
    }
}

/// `workflow.step.read`: a step, and the pass wanted (the current one by default).
public struct APIWorkflowStepRef: Codable, Equatable, Sendable {
    public var step: String
    public var pass: Int?
    public init(step: String, pass: Int? = nil) {
        self.step = step
        self.pass = pass
    }
}

/// A step's answer.
public struct APIWorkflowAnswer: Codable, Equatable, Sendable {
    public var step: String
    public var pass: Int
    public var status: String
    /// The structured answer (its fields), when it has one.
    public var output: JSONValue?
    public var text: String?
    public var error: String?
    /// A visible step: the last things it said in its session.
    public var recentMessages: [String]?

    public init(step: String, pass: Int, status: String, output: JSONValue? = nil, text: String? = nil,
                error: String? = nil, recentMessages: [String]? = nil) {
        self.step = step
        self.pass = pass
        self.status = status
        self.output = output
        self.text = text
        self.error = error
        self.recentMessages = recentMessages
    }
}

/// `workflow.step.ask`.
public struct APIWorkflowAskParams: Codable, Equatable, Sendable {
    public var step: String
    public var message: String
    public init(step: String, message: String) {
        self.step = step
        self.message = message
    }
}

/// `workflow.step.rerun`.
public struct APIWorkflowRerunParams: Codable, Equatable, Sendable {
    public var step: String
    public var instructions: String
    public init(step: String, instructions: String) {
        self.step = step
        self.instructions = instructions
    }
}

/// `workflow.step.skip`.
public struct APIWorkflowSkipParams: Codable, Equatable, Sendable {
    public var step: String
    public var reason: String?
    public init(step: String, reason: String? = nil) {
        self.step = step
        self.reason = reason
    }
}

/// `workflow.stop`, `workflow.proceed`.
public struct APIWorkflowReasonParams: Codable, Equatable, Sendable {
    public var reason: String?
    public init(reason: String? = nil) { self.reason = reason }
}

/// `workflow.message`: what a step writes to its orchestrator.
public struct APIWorkflowMessageParams: Codable, Equatable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

/// What an orchestrator's move did.
public struct APIWorkflowAck: Codable, Equatable, Sendable {
    public var message: String
    public var interventionsLeft: Int
    /// `workflow.step.ask`: the step's answer.
    public var answer: String?

    public init(message: String, interventionsLeft: Int, answer: String? = nil) {
        self.message = message
        self.interventionsLeft = interventionsLeft
        self.answer = answer
    }
}

/// What the API takes from a workflow's sessions.
public enum APIWorkflowLimits {
    /// A question, an instruction, a step's message.
    public static let messageMaxLength = 8_000
}

// MARK: - The workflow library (ADR-0020)

/// `library.workflow.get`: which workflow.
public struct APILibraryRef: Codable, Equatable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}

/// `library.run.request`: the Run sheet, filled in — the person starts it.
public struct APILibraryRunParams: Codable, Equatable, Sendable {
    public var workflowId: String
    public var projectId: String?
    public var prNumber: Int?
    public var jiraKey: String?
    public var note: String?

    public init(workflowId: String, projectId: String? = nil, prNumber: Int? = nil, jiraKey: String? = nil,
                note: String? = nil) {
        self.workflowId = workflowId
        self.projectId = projectId
        self.prNumber = prNumber
        self.jiraKey = jiraKey
        self.note = note
    }
}

/// What the library takes from an agent.
public enum APILibraryLimits {
    /// Proposals waiting on the person, all kinds together.
    public static let pendingProposals = 50
    public static let stepsPerWorkflow = 200
    /// A prompt, a rule, an instruction.
    public static let textMaxLength = 40_000
}

/// What an agent may write through the API. Loom's own tools run without a
/// permission prompt (pre-approved), so what they write is bounded here: a
/// session title also becomes a system notification's title, and a prompt-
/// injected agent must not be able to turn it into a message of its own.
public enum APILimits {
    public static let titleMaxLength = 80
    public static let badgesPerSession = 8
    public static let badgeNameMaxLength = 24
    /// Badge definitions the API may bring the catalog up to.
    public static let catalogMaxCount = 32

    /// One line, no control characters, at most `titleMaxLength` characters;
    /// empty when nothing printable is left.
    public static func sanitizedTitle(_ raw: String) -> String {
        let printable = raw.unicodeScalars.map { scalar -> String in
            if CharacterSet.newlines.contains(scalar) || scalar == "\t" { return " " }
            return CharacterSet.controlCharacters.contains(scalar) ? "" : String(scalar)
        }.joined()
        let collapsed = printable.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.prefix(titleMaxLength))
    }

    /// nil when the list is acceptable, the reason otherwise.
    public static func badgeProblem(_ badges: [String]) -> String? {
        if badges.count > badgesPerSession {
            return "at most \(badgesPerSession) badges per session"
        }
        if let long = badges.first(where: { $0.count > badgeNameMaxLength }) {
            return "badge name too long (\(badgeNameMaxLength) characters at most): \(long.prefix(40))"
        }
        return nil
    }
}
