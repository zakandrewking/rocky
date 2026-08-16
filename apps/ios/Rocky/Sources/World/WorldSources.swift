import Foundation

/// How the board reports itself, translated into the world model.
///
/// This is the only place the board's own vocabulary exists. Everything downstream -- the store,
/// the projector, the salience policy, what Rocky actually says -- is written against the
/// translated form, which is why none of it had to change when the commanded-motion agent was
/// deprecated and this became the only body.

/// Turns `rocky_agent.py`'s mode transitions into semantic state and events.
///
/// The board reports *which state machine state it entered*. That vocabulary is the board's, not
/// Rocky's -- "dizzy" and "recovering" are names in the tuning record. This is where they become
/// things a person could say, and it is the only place that mapping exists.
@MainActor
final class BehaviorWorldSource {
    private let store: WorldStore
    /// The gesture Rocky asked for, if one is still being carried out. The board honours gestures
    /// at its own seams, so this is how a transition it makes for its own reasons is told apart
    /// from one it made because she asked.
    private var gestureActionId: String?
    private var gestureRepeatsSeen = 0

    init(store: WorldStore) {
        self.store = store
    }

    func handle(_ message: BehaviorMessage) {
        store.heard()
        switch message {
        case .hello(let mode, let mood):
            store.noteFeeling(mood)
            apply(mode: mode, detail: "")
        case .snapshot(let mode, let mood):
            store.noteFeeling(mood)
            apply(mode: mode, detail: "")
        case .transition(let mode, let detail):
            note(mode: mode, detail: detail)
            apply(mode: mode, detail: detail)
        case .acknowledged(let of, let id):
            // The board has the intention in hand. Not "it is happening" -- it happens at the
            // loop's next safe seam, which may be a second or two away, and claiming otherwise is
            // exactly the kind of small lie this whole design exists to prevent.
            guard of == "gesture", let id, id == gestureActionId else { return }
            store.markAction(id, status: .accepted, evidence: .confirmed)
        case .disconnected:
            store.linkLost("the connection to my body dropped")
        }
    }

    /// A gesture Rocky just asked for. The board decides when; this only records that she asked.
    func expect(gesture actionId: String) {
        gestureActionId = actionId
        gestureRepeatsSeen = 0
    }

    // MARK: - Board vocabulary → Rocky's

    private func apply(mode: String, detail: String) {
        switch mode {
        case "listening":
            finishGestureIfDone()
            store.noteDoing(.still, cause: .onItsOwn)
        case "driving":
            store.noteDoing(.rollingForward, cause: .onItsOwn)
        case "settling":
            // A 180ms motor ring-down between two real states. Projected as stillness, and the
            // projector's coalescing window is longer than it is, so it never reaches Rocky as an
            // event in its own life -- which is correct, because it is a machine seam, not a
            // thing that happened.
            store.noteDoing(.still, cause: .onItsOwn)
        case "turning":
            if isGesture(detail) {
                store.noteDoing(.spinning, cause: .youAsked)
            } else if detail.contains("obstacle") {
                store.noteDoing(.turning, cause: .reflex)
            } else {
                store.noteDoing(.turning, cause: .onItsOwn)
            }
        case "startled":
            store.noteDoing(.backingAway, cause: .reflex)
        case "recovering":
            store.noteDoing(.lookingAround, cause: isGesture(detail) ? .youAsked : .reflex)
        case "dizzy":
            store.noteDoing(.spinning, cause: .reflex)
        default:
            store.noteDoing(.unknown, cause: .unknown)
        }
    }

    private func note(mode: String, detail: String) {
        switch mode {
        case "dizzy":
            store.record(.bumped, detail: "something touched me")
        case "startled":
            store.record(.startled, detail: detail.contains("close") ? "something came at me" : "a sudden loud noise")
        case "turning" where detail.contains("obstacle"):
            store.record(.blocked, detail: "something was in the way")
        case "listening" where detail.contains("expired"):
            guard let id = gestureActionId else { return }
            gestureActionId = nil
            store.markAction(id, status: .failed, reason: "my body never got a free moment for it")
        case "turning", "recovering":
            guard isGesture(detail), let id = gestureActionId else { return }
            gestureRepeatsSeen += 1
            store.markAction(id, status: .running, evidence: .confirmed, done: gestureRepeatsSeen)
        default:
            break
        }
    }

    private func isGesture(_ detail: String) -> Bool {
        detail.hasPrefix("gesture:")
    }

    /// A gesture is done when the board is back to sitting still with nothing left to repeat.
    private func finishGestureIfDone() {
        guard let id = gestureActionId, let action = store.action(id: id) else { return }
        guard action.status.isLive, gestureRepeatsSeen >= action.total else { return }
        gestureActionId = nil
        store.markAction(id, status: .succeeded, evidence: .confirmed)
    }
}
