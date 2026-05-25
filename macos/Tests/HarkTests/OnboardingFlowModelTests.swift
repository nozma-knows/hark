@testable import Hark
import XCTest

/// `OnboardingFlowModel` is pure navigation logic over a step-status
/// probe. These tests pin down:
///
/// 1. Initial landing — model jumps past steps already complete.
/// 2. Forward navigation — `advance()` skips complete + skipped steps.
/// 3. Backward navigation — `back()` never skips, even past complete.
/// 4. `canContinue` per step (welcome/tryIt always; perm steps gate
///    on complete; claude gates on resolved-or-skipped).
/// 5. `skip(.claudeAuth)` advances past Claude when the user opts out.
/// 6. `advanceIfCurrentStepCompleted()` advances only when the current
///    step (not a future step) flips to complete.
/// 7. `isFlowComplete` flips true after the last step is dismissed.
@MainActor
final class OnboardingFlowModelTests: XCTestCase {
    // MARK: - Initial landing

    func testInitialStepIsWelcomeWhenNothingComplete() {
        let probe = StatusProbe.allIncomplete()
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        XCTAssertEqual(model.step, .welcome)
    }

    func testInitialStepSkipsAlreadyGrantedPermissions() {
        let probe = StatusProbe.allIncomplete()
        probe.set(.microphone, complete: true)
        probe.set(.accessibility, complete: true)
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        // Welcome is "needs a click", microphone + accessibility are
        // already complete, so we should land on inputMonitoring.
        XCTAssertEqual(
            model.step,
            .welcome,
            "welcome is incomplete by definition — model should still land here first"
        )

        // Advance past welcome.
        model.advance()
        XCTAssertEqual(
            model.step,
            .inputMonitoring,
            "advance() skips microphone + accessibility"
        )
    }

    func testInitialStepLandsOnFirstIncompletePermission() {
        let probe = StatusProbe.allIncomplete()
        probe.set(.microphone, complete: true)
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        model.advance() // past welcome
        XCTAssertEqual(model.step, .accessibility)
    }

    // MARK: - Forward navigation

    func testAdvanceSkipsCompleteSteps() {
        let probe = StatusProbe.allIncomplete()
        probe.set(.accessibility, complete: true)
        probe.set(.inputMonitoring, complete: true)
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        model.advance() // welcome → microphone
        XCTAssertEqual(model.step, .microphone)
        probe.set(.microphone, complete: true)
        model.advance() // microphone → claudeAuth (ax + im are complete)
        XCTAssertEqual(model.step, .claudeAuth)
    }

    func testAdvanceFlipsIsFlowCompleteAtEnd() {
        let probe = StatusProbe.allComplete()
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        // All perms already complete — initial step is welcome (always
        // incomplete), and tryIt (also always incomplete) is the only
        // other one left.
        XCTAssertEqual(model.step, .welcome)
        XCTAssertFalse(model.isFlowComplete)
        model.advance() // welcome → tryIt (skips all complete perms)
        XCTAssertEqual(model.step, .tryIt)
        model.advance() // tryIt → done
        XCTAssertTrue(model.isFlowComplete)
    }

    func testAdvanceOnLastStepFlipsCompletionFlag() {
        let probe = StatusProbe.allComplete()
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        // Force directly to tryIt by advancing through welcome.
        model.advance()
        XCTAssertEqual(model.step, .tryIt)
        XCTAssertFalse(model.isFlowComplete)
        model.advance()
        XCTAssertTrue(model.isFlowComplete)
    }

    // MARK: - Back navigation

    func testBackMovesOneStepEvenIfPreviousIsComplete() {
        let probe = StatusProbe.allIncomplete()
        probe.set(.microphone, complete: true)
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        model.advance() // welcome → accessibility (skips granted mic)
        XCTAssertEqual(model.step, .accessibility)
        model.back()
        XCTAssertEqual(
            model.step,
            .microphone,
            "back() must NOT skip complete steps — the user wants to see what they just did"
        )
    }

    func testBackFromWelcomeIsNoOp() {
        let probe = StatusProbe.allIncomplete()
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        XCTAssertFalse(model.canGoBack)
        model.back()
        XCTAssertEqual(model.step, .welcome)
    }

    // MARK: - canContinue

    func testCanContinueWelcomeAlwaysTrue() {
        let probe = StatusProbe.allIncomplete()
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        XCTAssertEqual(model.step, .welcome)
        XCTAssertTrue(model.canContinue)
    }

    func testCanContinuePermissionStepRequiresGrant() {
        let probe = StatusProbe.allIncomplete()
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        model.advance() // welcome → microphone
        XCTAssertEqual(model.step, .microphone)
        XCTAssertFalse(model.canContinue)

        probe.set(.microphone, complete: true)
        XCTAssertTrue(model.canContinue)
    }

    func testCanContinueClaudeStepAllowsSkip() {
        let probe = StatusProbe.allIncomplete()
        probe.set(.microphone, complete: true)
        probe.set(.accessibility, complete: true)
        probe.set(.inputMonitoring, complete: true)
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        model.advance() // welcome → claude (all perms complete)
        XCTAssertEqual(model.step, .claudeAuth)
        // Continue should be true even without claude — user can skip.
        XCTAssertTrue(model.canContinue)
    }

    // MARK: - Skip

    func testSkipClaudeAdvancesPastIt() {
        let probe = StatusProbe.allIncomplete()
        probe.set(.microphone, complete: true)
        probe.set(.accessibility, complete: true)
        probe.set(.inputMonitoring, complete: true)
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        model.advance() // welcome → claude
        XCTAssertEqual(model.step, .claudeAuth)
        model.skip(.claudeAuth)
        XCTAssertEqual(model.step, .tryIt)
        XCTAssertEqual(model.status(of: .claudeAuth), .skipped)
    }

    func testCannotSkipPermissionSteps() {
        let probe = StatusProbe.allIncomplete()
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        XCTAssertFalse(model.canSkip(.microphone))
        XCTAssertFalse(model.canSkip(.accessibility))
        XCTAssertFalse(model.canSkip(.inputMonitoring))
        XCTAssertTrue(model.canSkip(.claudeAuth))
    }

    // MARK: - Reactive advance

    func testAdvanceIfCurrentStepCompletedFlipsOnGrant() {
        let probe = StatusProbe.allIncomplete()
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        model.advance() // welcome → microphone
        XCTAssertEqual(model.step, .microphone)
        probe.set(.microphone, complete: true)
        model.advanceIfCurrentStepCompleted()
        XCTAssertEqual(model.step, .accessibility)
    }

    func testAdvanceIfCurrentStepCompletedIgnoresOtherSteps() {
        let probe = StatusProbe.allIncomplete()
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        model.advance() // welcome → microphone
        XCTAssertEqual(model.step, .microphone)
        // Accessibility grant arriving while user is on microphone:
        // should NOT yank them forward.
        probe.set(.accessibility, complete: true)
        model.advanceIfCurrentStepCompleted()
        XCTAssertEqual(model.step, .microphone)
    }

    // MARK: - Status

    func testTryItStatusIsAlwaysIncomplete() {
        let probe = StatusProbe.allComplete()
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        XCTAssertEqual(
            model.status(of: .tryIt),
            .incomplete,
            "tryIt is a verification step — its status flips on user click, not on system state"
        )
    }

    func testWelcomeStatusIsAlwaysIncomplete() {
        let probe = StatusProbe.allComplete()
        let model = OnboardingFlowModel(dependencies: probe.dependencies)
        XCTAssertEqual(model.status(of: .welcome), .incomplete)
    }
}

// MARK: - Test seam

/// Mutable bag of step statuses the tests drive the model with. Models a
/// permissions/auth probe by mapping each step to a bool ("requirement
/// met"). The model's `Dependencies.isStepRequirementMet` closure reads
/// from this bag on every call, so tests can mutate state mid-flow and
/// trigger `advanceIfCurrentStepCompleted()` to verify reactive behavior.
@MainActor
private final class StatusProbe {
    private var complete: [OnboardingStep: Bool] = [:]

    static func allIncomplete() -> StatusProbe {
        let probe = StatusProbe()
        for step in OnboardingStep.ordered {
            probe.complete[step] = false
        }
        return probe
    }

    static func allComplete() -> StatusProbe {
        let probe = StatusProbe()
        for step in OnboardingStep.ordered {
            probe.complete[step] = true
        }
        return probe
    }

    func set(_ step: OnboardingStep, complete: Bool) {
        self.complete[step] = complete
    }

    var dependencies: OnboardingFlowModel.Dependencies {
        OnboardingFlowModel.Dependencies(
            isStepRequirementMet: { [weak self] step in
                self?.complete[step] ?? false
            }
        )
    }
}
