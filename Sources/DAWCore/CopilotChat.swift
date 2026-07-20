import Foundation

/// One persisted copilot conversation — the disk twin of the engine's
/// transcript + (thinking-stripped, L1) provider history
/// (docs/research/design-copilot-chat-persistence.md §3). Pure Codable DTO:
/// string-typed `kind`/`type`/`role` discriminators so a file written by a
/// FUTURE build (new entry kinds) still decodes today — unknown kinds are
/// skipped on resume and counted into `droppedEntries`, per L6.
///
/// L1 (load-bearing; do not "fix" later): persisted `providerMessages` NEVER
/// contain thinking blocks. Anthropic's verbatim-echo requirement for
/// `thinking`/`redacted_thinking` blocks is load-bearing only WITHIN an
/// in-flight tool-use loop; persisted chats only ever exist at turn
/// boundaries, where the blocks are not required and their signatures may
/// not validate after a model switch. The thinking SUMMARIES stay in the
/// persisted `transcript` (kind `"thinking"`) for display. This is not data
/// loss — it is the only shape that makes resumed chats model-switch-safe.
public struct CopilotChatDocument: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Derived from the first user message; renameable (≤ `maxTitleLength`).
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Last model in effect (informational only — resume is model-agnostic
    /// by construction, L1).
    public var model: String?
    /// L6 honesty counter: how many transcript entries cap-enforcement has
    /// dropped over this chat's lifetime. Omitted when 0/absent — the
    /// persisted transcript never silently pretends to be complete.
    public var droppedEntries: Int?
    public var transcript: [Entry]
    public var providerMessages: [ProviderMessage]

    public init(
        id: UUID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        model: String? = nil,
        droppedEntries: Int? = nil,
        transcript: [Entry] = [],
        providerMessages: [ProviderMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.droppedEntries = droppedEntries
        self.transcript = transcript
        self.providerMessages = providerMessages
    }

    /// One display-transcript line. Field names deliberately mirror
    /// `CopilotEngine.stateJSON`'s wire entry shape (`kind`/`text`/`command`/
    /// `ok`/`summary`), so the persisted and wire surfaces can never drift
    /// apart vocabulary-wise.
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var turnId: String
        /// "user" | "assistant" | "thinking" | "toolCall" | "toolResult" | "failure"
        public var kind: String
        /// user/assistant/thinking/failure
        public var text: String?
        /// toolCall/toolResult
        public var command: String?
        /// toolResult
        public var ok: Bool?
        /// toolCall(args)/toolResult
        public var summary: String?

        public init(
            id: UUID = UUID(),
            turnId: String,
            kind: String,
            text: String? = nil,
            command: String? = nil,
            ok: Bool? = nil,
            summary: String? = nil
        ) {
            self.id = id
            self.turnId = turnId
            self.kind = kind
            self.text = text
            self.command = command
            self.ok = ok
            self.summary = summary
        }
    }

    /// One provider-history message (the model's own memory of the
    /// conversation, already bounded by the engine's `historyLimit` trims).
    public struct ProviderMessage: Codable, Sendable, Equatable {
        /// "user" | "assistant"
        public var role: String
        public var blocks: [Block]

        public init(role: String, blocks: [Block]) {
            self.role = role
            self.blocks = blocks
        }

        public struct Block: Codable, Sendable, Equatable {
            /// "text" | "toolUse" | "toolResult" — NEVER "thinking" (L1).
            public var type: String
            /// text
            public var text: String?
            /// toolUse / toolResult
            public var toolUseId: String?
            /// toolUse (wire tool name)
            public var name: String?
            /// toolUse input, UTF-8 JSON text
            public var inputJSON: String?
            /// toolResult
            public var content: String?
            /// toolResult
            public var isError: Bool?

            public init(
                type: String,
                text: String? = nil,
                toolUseId: String? = nil,
                name: String? = nil,
                inputJSON: String? = nil,
                content: String? = nil,
                isError: Bool? = nil
            ) {
                self.type = type
                self.text = text
                self.toolUseId = toolUseId
                self.name = name
                self.inputJSON = inputJSON
                self.content = content
                self.isError = isError
            }
        }
    }
}

/// Persistence policy for copilot chats (beside `CopilotLimits` — the same
/// DAWCore-policy precedent: one source of truth consumed by DAWControl's
/// engine/mapping and, later, the UI). See the chat-persist design §7 for the
/// eviction/truncation laws these numbers drive.
public enum CopilotChatLimits {
    /// Max ARCHIVED chats per project (the active chat is excluded). Archiving
    /// at the cap evicts the oldest-`updatedAt` archived chat — never
    /// silently: the evicted id surfaces to the wire (`evictedChatId`).
    public static let maxArchivedChats = 20
    /// Max persisted transcript entries per chat. Over-cap drops the OLDEST
    /// WHOLE TURNS (a turn is never half-shown), counted into
    /// `droppedEntries` (L6).
    public static let maxPersistedTranscriptEntries = 400
    /// 256 KiB soft cap on one encoded chat. When over: first drop oldest
    /// provider EXCHANGES (min 1 kept — provider trims reduce only the
    /// model's memory), then oldest transcript turns (counted, L6).
    public static let maxPersistedChatBytes = 262_144
    /// Rename cap — over-length titles are clamped, never an error.
    public static let maxTitleLength = 120
    /// Auto-derived title length (from the first user message).
    public static let derivedTitleLength = 60
    /// Project-level honesty threshold: a save whose encoded chats total
    /// exceeds this gains a size warning (warn, never refuse — the
    /// `audioUnitStateSoftCapBytes` precedent).
    public static let totalChatBytesWarningThreshold = 4 * 1024 * 1024
}

/// Element-lossy array decoding (chat-persist design §3): decodes an unkeyed
/// container element by element, SKIPPING elements that fail to decode and
/// counting them — so one corrupt chat can never fail a whole project open.
/// The skip count surfaces as an open warning ("N copilot chats could not be
/// read and were dropped"). Encodes as a plain array (the wrapper never
/// appears on disk).
struct LossyArray<Element: Codable>: Codable {
    var elements: [Element]
    /// How many elements failed to decode and were skipped. Never encoded.
    var droppedCount: Int

    init(elements: [Element], droppedCount: Int = 0) {
        self.elements = elements
        self.droppedCount = droppedCount
    }

    /// Decodes anything (its `init` consumes no fields and never throws) —
    /// the standard advance-past-a-corrupt-element trick for unkeyed
    /// containers, whose index only moves on a SUCCESSFUL decode.
    private struct SkippedElement: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                decoded.append(element)
            } else {
                // Advance past the corrupt element. If even the
                // accept-anything placeholder fails (a pathological decoder),
                // bail rather than loop forever — the remainder is dropped.
                guard (try? container.decode(SkippedElement.self)) != nil else {
                    dropped += 1
                    break
                }
                dropped += 1
            }
        }
        elements = decoded
        droppedCount = dropped
    }

    func encode(to encoder: any Encoder) throws {
        try elements.encode(to: encoder)
    }
}
