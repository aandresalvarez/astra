import Testing
@testable import ASTRA

@Suite("Sidebar Peek Policy")
struct SidebarPeekPolicyTests {

    @Test("Opens while the toggle is hovered")
    func opensOnTriggerHover() {
        #expect(SidebarPeekPolicy.shouldOpen(triggerHovered: true, panelHovered: false))
    }

    @Test("Opens while the panel is hovered (pointer moved into the peek)")
    func opensOnPanelHover() {
        #expect(SidebarPeekPolicy.shouldOpen(triggerHovered: false, panelHovered: true))
    }

    @Test("Stays open when both the toggle and panel are hovered")
    func opensWhenBothHovered() {
        #expect(SidebarPeekPolicy.shouldOpen(triggerHovered: true, panelHovered: true))
    }

    @Test("Does not open when neither is hovered")
    func staysClosedWhenNeitherHovered() {
        #expect(!SidebarPeekPolicy.shouldOpen(triggerHovered: false, panelHovered: false))
    }

    @Test("Dismisses only once both the toggle and panel are unhovered")
    func dismissRequiresBothUnhovered() {
        #expect(SidebarPeekPolicy.shouldDismiss(triggerHovered: false, panelHovered: false))
        #expect(!SidebarPeekPolicy.shouldDismiss(triggerHovered: true, panelHovered: false))
        #expect(!SidebarPeekPolicy.shouldDismiss(triggerHovered: false, panelHovered: true))
        #expect(!SidebarPeekPolicy.shouldDismiss(triggerHovered: true, panelHovered: true))
    }

    @Test("Open and dismiss are exact complements")
    func openAndDismissAreComplements() {
        for trigger in [true, false] {
            for panel in [true, false] {
                let open = SidebarPeekPolicy.shouldOpen(triggerHovered: trigger, panelHovered: panel)
                let dismiss = SidebarPeekPolicy.shouldDismiss(triggerHovered: trigger, panelHovered: panel)
                #expect(open != dismiss)
            }
        }
    }

    @Test("Dismiss grace window is a positive, sub-second delay")
    func dismissDelayIsReasonable() {
        #expect(SidebarPeekPolicy.dismissDelayNanoseconds > 0)
        #expect(SidebarPeekPolicy.dismissDelayNanoseconds < 1_000_000_000)
    }
}
