import SwiftUI

// Check-ins in the app (docs/Sharing.md "Check-ins"): the same as the Lock Screen buttons, for
// when GlucOS is open.

/// On the owner's home screen while someone's waiting to hear they're okay.
struct PhoneCheckInBanner: View {
    @EnvironmentObject var services: PhoneServices
    @State private var sending: CheckInAnswer.Answer?
    @State private var error: String?

    var body: some View {
        if let c = services.waitingCheckIn {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Label("\(c.askers) \((c.count ?? 1) > 1 ? "are" : "is") checking in on you", systemImage: "hand.wave.fill")
                    .dsFont(.headline)
                    .foregroundStyle(Tone.warning.textColor)
                Text(c.status == .noAnswer
                     ? "Waiting since \(c.askedDate.formatted(date: .omitted, time: .shortened)). Let them know how you are."
                     : "Asked at \(c.askedDate.formatted(date: .omitted, time: .shortened)). Let them know how you are.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: DS.Space.sm) {
                    Button { answer(.okay) } label: {
                        Label("I'm okay", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tone.success.color)
                    Button(role: .destructive) { answer(.help) } label: {
                        Label("I need help", systemImage: "exclamationmark.triangle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(sending != nil)
                if let error {
                    Text(error).dsFont(.caption).foregroundStyle(Tone.warning.textColor)
                }
            }
            .padding(DS.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { DSSurface(style: .tinted(.warning), radius: DS.Radius.card) }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func answer(_ a: CheckInAnswer.Answer) {
        sending = a
        error = nil
        Task {
            do { try await services.answerCheckIn(a) } catch { self.error = error.localizedDescription }
            sending = nil
        }
    }
}

/// Under a followed reading: Check in (bold while they're low), and how the last check-in went.
struct FollowCheckInRow: View {
    @EnvironmentObject var follows: FollowStore
    let follow: Follow
    let card: GlucoseActivityState
    @State private var error: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let checkIn = follows.checkIns[follow.id]
        // Always offered: anyone worried can ask, not only during a low. A low (or no answer)
        // makes it the bold one.
        let urgent = (card.offersCheckIn && !card.isStale()) || checkIn?.status == .noAnswer
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
                if let checkIn {
                    // A new answer pushes the old line up and out, so "is okay" arriving is seen.
                    status(checkIn)
                        .id(checkIn.status)
                        .transition(reduceMotion ? .opacity : .push(from: .bottom))
                }
                Spacer(minLength: 0)
                if checkIn.map({ !$0.isWaiting || $0.status == .noAnswer }) ?? true {
                    askButton(title: checkIn?.status == .noAnswer ? "Ask again" : "Check in", urgent: urgent)
                        .disabled(follows.checkingIn.contains(follow.id))
                        .accessibilityHint("Asks \(follow.label) if they're okay")
                }
            }
            if let error {
                Text(error).dsFont(.caption).foregroundStyle(Tone.warning.textColor)
            } else if checkIn == nil, follows.myName.isEmpty {
                Text("Add your name in Settings so \(follow.label) knows who's asking.")
                    .dsFont(.caption).foregroundStyle(.secondary)
            }
        }
        .clipped()
        .dsAnimation(.emphasized, value: checkIn?.status)
        // The answer is felt as well as seen: success for "okay", a warning for "needs help" or
        // no answer. Only on a change while this screen is open, never on first draw.
        .sensoryFeedback(trigger: checkIn?.status) { old, new in
            guard old != nil, old != new else { return nil }
            switch new {
            case .okay: return .success
            case .help, .noAnswer: return .warning
            case .asked, nil: return nil
            }
        }
    }

    @ViewBuilder
    private func askButton(title: String, urgent: Bool) -> some View {
        let button = Button {
            error = nil
            Task {
                do { try await follows.checkIn(follow.id) } catch { self.error = error.localizedDescription }
            }
        } label: {
            Label(title, systemImage: "hand.wave.fill")
        }
        if urgent {
            button.buttonStyle(.borderedProminent).tint(Tone.warning.color)
        } else {
            button.buttonStyle(.bordered).tint(Palette.brand)
        }
    }

    @ViewBuilder
    private func status(_ c: CheckInState) -> some View {
        let time = (c.answeredDate ?? c.askedDate).formatted(date: .omitted, time: .shortened)
        switch c.status {
        case .asked:
            Label("Checked in at \(time), waiting", systemImage: "hand.wave.fill")
                .dsFont(.callout).foregroundStyle(.secondary)
        case .noAnswer:
            Label("No answer since \(time)", systemImage: "exclamationmark.triangle.fill")
                .dsFont(.callout).foregroundStyle(Tone.warning.textColor)
        case .okay:
            Label("\(follow.label) is okay (\(time))", systemImage: "checkmark.circle.fill")
                .dsFont(.callout).foregroundStyle(Tone.success.textColor)
        case .help:
            Label("\(follow.label) needs help (\(time))", systemImage: "exclamationmark.triangle.fill")
                .dsFont(.callout).fontWeight(.semibold).foregroundStyle(Tone.critical.textColor)
        }
    }
}

