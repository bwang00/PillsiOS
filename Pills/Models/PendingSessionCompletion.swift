import Foundation
import SwiftData

/// A practice-session upload that could not reach the backend.
///
/// Breathing practice data must survive transient network failures. Two
/// failure modes are captured here:
///
/// 1. The session was created server-side but `completeSession` failed.
///    `sessionID` is set and the flush only needs to retry the completion.
/// 2. `createSession` itself failed, so the practice ran entirely offline.
///    `sessionID` is nil and the flush must first create the session (using
///    `guideSlug`) and then complete it with the recorded duration.
///
/// `recordID` is a local unique key so multiple queued practices (including
/// several without a server session id) can coexist.
@Model
final class PendingSessionCompletion {
    @Attribute(.unique) var recordID: String
    var sessionID: String?
    var guideSlug: String
    var durationSeconds: Int
    /// Per-practice idempotency key sent as the ``Idempotency-Key`` header when
    /// the flush must create the session. Reusing the same key across retries
    /// lets the backend return the already-committed session instead of
    /// inserting a duplicate when an earlier create's response was lost.
    var idempotencyKey: String?
    var createdAt: Date

    init(
        recordID: String = UUID().uuidString,
        sessionID: String?,
        guideSlug: String,
        durationSeconds: Int,
        idempotencyKey: String? = nil,
        createdAt: Date = Date()
    ) {
        self.recordID = recordID
        self.sessionID = sessionID
        self.guideSlug = guideSlug
        self.durationSeconds = durationSeconds
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
    }
}

/// Drains queued session completions.
///
/// Shared by `BreathingViewModel` (flush before the next practice) and the
/// app shell (flush on launch once signed in) so the retry logic lives in one
/// place. The re-entrancy guard prevents two overlapping flushes from both
/// creating a server-side session for the same offline record.
@MainActor
enum SessionCompletionQueue {
    private static var isFlushing = false

    static func flush(modelContext: ModelContext, api: BreathingSessionAPI) async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        let descriptor = FetchDescriptor<PendingSessionCompletion>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let pending: [PendingSessionCompletion]
        do {
            pending = try modelContext.fetch(descriptor)
        } catch {
            print("⚠️ Failed to load pending completions: \(error)")
            return
        }

        for record in pending {
            do {
                let sessionID: String
                if let existingID = record.sessionID {
                    sessionID = existingID
                } else {
                    let created = try await api.createSession(
                        guideSlug: record.guideSlug,
                        idempotencyKey: record.idempotencyKey
                    )
                    sessionID = created.id
                    // Persist the new id immediately: if the completion below
                    // fails, a later flush retries the completion instead of
                    // creating a second server-side session.
                    record.sessionID = created.id
                    try? modelContext.save()
                }
                _ = try await api.completeSession(
                    id: sessionID,
                    durationSeconds: record.durationSeconds
                )
            } catch {
                print("⚠️ Pending completion retry failed for \(record.guideSlug): \(error)")
                // Stop on the first failure so we preserve ordering and avoid
                // hammering the backend while it is still unreachable.
                try? modelContext.save()
                return
            }
            modelContext.delete(record)
        }
        if !pending.isEmpty {
            try? modelContext.save()
        }
    }
}
