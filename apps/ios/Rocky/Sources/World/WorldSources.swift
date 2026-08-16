import Foundation

/// The two ways a body reports itself, translated into the one world model.
///
/// Only one payload ever runs on the board at a time (`rocky_agent.py` takes commands;
/// `rocky_behavior.py` moves on its own), so these are alternatives, never both -- the same fact
/// BehaviorMonitor's single network sweep already encodes. Keeping the translation here rather
/// than inside either transport is what lets the rest of the system stop caring which body it
/// has: the store, the projector and the salience policy are written once.

// MARK: - The autonomous behaviour loop

/// Turns `rocky_behavior.py`'s mode transitions into semantic state and events.
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

// MARK: - The motion agent

/// Turns `rocky_agent.py`'s command replies into action lifecycle.
///
/// The interesting asymmetry lives here. That agent acks only on *completion*, so between writing
/// the bytes and hearing back there is genuinely nothing to know -- and rather than invent a
/// `started` it never sent, an accepted action becomes `running`/`assumed` after a beat, and the
/// projection says out loud that it is assumed. (`rocky_agent.py` does now send a `started` for
/// drives and turns, which upgrades that to `confirmed`; the assumed path stays because it is
/// what an older board on the same protocol still gives us.)
@MainActor
final class MotionWorldSource {
    private let store: WorldStore

    init(store: WorldStore) {
        self.store = store
    }

    func handle(_ report: ActionReport) {
        store.heard()
        switch report {
        case .started(let actionId):
            // `started` and `running` are the same instant on this hardware -- the board says the
            // maneuver began and then says nothing until it ends. Recording both would be two
            // transitions describing one fact; `started` is the one the board actually sent, and
            // `running` stays for the belief the world model reaches on its own when no `started`
            // ever arrives (an older payload on the same protocol).
            store.markAction(actionId, status: .started, evidence: .confirmed)
        case .succeeded(let actionId):
            store.markAction(actionId, status: .succeeded, evidence: .confirmed)
            store.noteDoing(.still, cause: .onItsOwn)
        case .blocked(let actionId, let reason):
            store.markAction(actionId, status: .blocked, reason: reason)
            store.noteBlocked(reason)
        case .failed(let actionId, let reason):
            store.markAction(actionId, status: .failed, reason: reason)
            store.noteDoing(.still, cause: .onItsOwn)
        case .lost(let actionId, let reason):
            store.markAction(actionId, status: .lost, reason: reason)
        case .distance(let cm):
            store.noteDistance(cm: cm)
        case .alive:
            break  // store.heard() above is the whole point of this one
        case .gone(let reason):
            store.linkLost(reason)
        }
    }

    /// What the body is doing the instant a movement command goes out. Not confirmation -- the
    /// action's own `evidence` carries that -- but the observable posture, which is what `moving`
    /// in the projection reports.
    func expect(_ intent: ActionIntent) {
        switch intent {
        case .driveForward: store.noteDoing(.rollingForward, cause: .youAsked)
        case .driveBackward: store.noteDoing(.rollingBack, cause: .youAsked)
        case .turn: store.noteDoing(.turning, cause: .youAsked)
        case .spin: store.noteDoing(.spinning, cause: .youAsked)
        case .stop, .settle: store.noteDoing(.still, cause: .youAsked)
        case .wiggle, .look: store.noteDoing(.lookingAround, cause: .youAsked)
        }
    }
}
