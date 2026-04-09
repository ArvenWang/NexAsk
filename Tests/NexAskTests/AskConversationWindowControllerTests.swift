import AppKit
import XCTest
@testable import NexShared
@testable import NexAskCore

@MainActor
final class AskConversationWindowControllerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
    }

    func testLoadingStatusStaysInlineAfterLatestUserMessage() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 0, height: 0),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )
        controller.testingStartStreamingTurn(prompt: "请稳定地继续往下输出")

        let snapshot = controller.testingTranscriptViewportSnapshot()
        XCTAssertGreaterThanOrEqual(snapshot.loadingStatusVisibleMinY, 0)
        XCTAssertGreaterThan(snapshot.lastUserRowVisibleMaxY, 0)
        XCTAssertGreaterThanOrEqual(snapshot.loadingStatusVisibleMinY + 0.5, snapshot.lastUserRowVisibleMaxY)
        XCTAssertLessThan(snapshot.loadingStatusVisibleMinY, snapshot.visibleHeight)
        controller.hide()
    }

    func testPreserveViewportRefreshOverridesPendingScrollToBottomIntent() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 0, height: 0),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingScheduleTranscriptViewportRefresh(scrollToBottom: true)
        XCTAssertTrue(controller.testingPendingTranscriptViewportShouldScrollToBottom())

        controller.testingScheduleTranscriptViewportRefresh(scrollToBottom: false)
        XCTAssertFalse(controller.testingPendingTranscriptViewportShouldScrollToBottom())
        controller.hide()
    }

    func testSendButtonAcceptsFirstMouseWhenWindowIsInactive() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 0, height: 0),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        let otherWindow = NSWindow(
            contentRect: CGRect(x: 40, y: 40, width: 160, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        otherWindow.orderFront(nil)
        otherWindow.makeKey()

        XCTAssertTrue(controller.testingSendButtonAcceptsFirstMouse())

        otherWindow.orderOut(nil)
        controller.hide()
    }

    func testComposerMarkedTextCommitsBeforeSubmit() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 0, height: 0),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        let committed = controller.testingCommitComposerMarkedText("你好，Ask")
        XCTAssertEqual(committed, "你好，Ask")

        controller.hide()
    }

    func testCompactComposerStaysSingleLineAndKeepsSendButtonBottomAligned() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 320, height: 220),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )
        controller.testingResizePanel(to: CGSize(width: 320, height: 220))

        controller.testingSetComposerText(Array(repeating: "compact-single-line-composer-0123456789", count: 8).joined())
        let snapshot = controller.testingComposerMetricsSnapshot()

        XCTAssertTrue(
            snapshot.isCompactLayout,
            "Expected compact layout at width \(snapshot.panelWidth), got textHeight=\(snapshot.textHeight)"
        )
        XCTAssertLessThanOrEqual(snapshot.textHeight, 28, "panelWidth=\(snapshot.panelWidth)")
        XCTAssertGreaterThanOrEqual(snapshot.textRightGap, 12, "panelWidth=\(snapshot.panelWidth)")
        XCTAssertGreaterThan(
            snapshot.textContentWidth,
            snapshot.textViewportWidth,
            "compact composer should allow the single-line content to extend beyond the visible viewport"
        )
        XCTAssertGreaterThan(snapshot.textScrollOffsetX, 0, "compact composer should keep the caret end visible by scrolling horizontally")
        controller.hide()
    }

    func testWideComposerExpandsUpToTwoLinesThenResetsAfterSubmit() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 280),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )
        controller.testingResizePanel(to: CGSize(width: 560, height: 280))

        controller.testingSetComposerText(Array(repeating: "wide composer should wrap naturally", count: 12).joined(separator: " "))
        let expandedSnapshot = controller.testingComposerMetricsSnapshot()

        XCTAssertFalse(expandedSnapshot.isCompactLayout)
        XCTAssertGreaterThan(expandedSnapshot.textHeight, 28)
        XCTAssertLessThanOrEqual(expandedSnapshot.textHeight, 44)

        controller.submitCurrentPrompt()
        let resetSnapshot = controller.testingComposerMetricsSnapshot()

        XCTAssertLessThan(resetSnapshot.textHeight, expandedSnapshot.textHeight)
        XCTAssertLessThanOrEqual(resetSnapshot.textHeight, 28)
        controller.hide()
    }

    func testAskWindowGeometryClampsVeryWideSelectionsToComfortWidth() {
        let frame = AskWindowGeometry.resolvedFrame(
            for: CGRect(x: 0, y: 0, width: 1600, height: 320),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        XCTAssertLessThanOrEqual(frame.width, AskWindowGeometry.maximumComfortableWidth)
    }

    func testPanelMouseDownFallbackSubmitsInsideSendButtonFrame() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 0, height: 0),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingSetComposerText("12345")
        controller.testingSetSendButtonEnabled(false)
        controller.testingRoutePanelMouseDownToSendButton()

        XCTAssertTrue(controller.testingIsStreaming())
        controller.hide()
    }

    func testFocusedComposerMouseClickSubmitsWithoutSecondClick() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 0, height: 0),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingSetComposerText("12345")
        controller.testingClickSendButtonWhileComposerIsFocused()

        XCTAssertTrue(controller.testingIsStreaming())
        controller.hide()
    }

    func testFocusedComposerMouseDownAloneSubmitsImmediately() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 0, height: 0),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingSetComposerText("12345")
        controller.testingRouteSendButtonMouseDownWhileComposerIsFocused()

        XCTAssertTrue(controller.testingIsStreaming())
        controller.hide()
    }

    func testPanelMouseDownStillSubmitsWhenComposerHasTextButButtonStateIsStale() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 0, height: 0),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingSetComposerText("12345")
        controller.testingSetSendButtonEnabled(false)
        controller.testingRoutePanelMouseDownToSendButton()

        XCTAssertTrue(controller.testingIsStreaming())
        controller.hide()
    }

    func testStreamingWrapKeepsAssistantRowAnchoredInViewport() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 0, height: 0),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )
        controller.testingStartStreamingTurn(prompt: "请稳定地继续往下输出")

        let response = Array(repeating: "streaming viewport stability check ", count: 80).joined()
        var fullText = ""
        var baselineScrollOffset: CGFloat?
        var previousScrollOffset: CGFloat?
        var previousRowHeight: CGFloat = 0
        var previousVisibleMinY: CGFloat?
        var wrapEvents = 0
        var autoFollowEvents = 0

        for chunk in responseChunks(from: response, chunkSize: 8) {
            fullText += chunk
            controller.testingApplyAssistantDelta(delta: chunk, fullText: fullText)
            let snapshot = controller.testingTranscriptViewportSnapshot()

            if baselineScrollOffset == nil, snapshot.assistantRowHeight > 0 {
                baselineScrollOffset = snapshot.scrollOffsetY
                previousScrollOffset = snapshot.scrollOffsetY
                previousVisibleMinY = snapshot.assistantRowVisibleMinY
            }

            if previousRowHeight > 0,
               snapshot.assistantRowHeight > previousRowHeight + 0.5 {
                wrapEvents += 1
                XCTAssertGreaterThanOrEqual(
                    snapshot.scrollOffsetY + 0.5,
                    previousScrollOffset ?? snapshot.scrollOffsetY
                )

                if abs(snapshot.scrollOffsetY - (previousScrollOffset ?? snapshot.scrollOffsetY)) <= 0.5 {
                    XCTAssertEqual(snapshot.scrollOffsetY, baselineScrollOffset ?? 0, accuracy: 0.5)
                    XCTAssertGreaterThanOrEqual(
                        snapshot.assistantRowVisibleMinY + 0.5,
                        previousVisibleMinY ?? snapshot.assistantRowVisibleMinY
                    )
                } else {
                    autoFollowEvents += 1
                    XCTAssertGreaterThanOrEqual(
                        snapshot.scrollOffsetY,
                        baselineScrollOffset ?? snapshot.scrollOffsetY
                    )
                }
            }

            if snapshot.assistantRowHeight > 0 {
                previousRowHeight = snapshot.assistantRowHeight
                previousVisibleMinY = snapshot.assistantRowVisibleMinY
                previousScrollOffset = snapshot.scrollOffsetY
            }
        }

        XCTAssertGreaterThan(wrapEvents, 3, "Expected several wrap-driven height increases during streaming.")
        XCTAssertGreaterThan(autoFollowEvents, 1, "Expected the viewport to auto-follow once the streaming row outgrows the visible area.")
        controller.testingFinishAssistantResponse(fullText)
        controller.hide()
    }

    func testStreamingDeltaStartsHighlightFadeForFreshSuffix() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 0, height: 0),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )
        controller.testingStartStreamingTurn(prompt: "请继续输出")

        controller.testingApplyAssistantDelta(
            delta: "hello",
            fullText: "hello"
        )

        let controllerHighlight = controller.testingStreamingHighlightState()
        XCTAssertNotNil(controllerHighlight.entryID)
        XCTAssertGreaterThan(controllerHighlight.suffixLength, 0)
        XCTAssertLessThan(controllerHighlight.alpha, 1)

        let initialRenderHighlight = controller.testingRenderedStreamingHighlightState()
        XCTAssertGreaterThan(initialRenderHighlight.suffixLength, 0)
        XCTAssertLessThan(initialRenderHighlight.alpha, 1)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))

        let progressedRenderHighlight = controller.testingRenderedStreamingHighlightState()
        XCTAssertGreaterThan(progressedRenderHighlight.alpha, initialRenderHighlight.alpha)
        XCTAssertLessThanOrEqual(progressedRenderHighlight.alpha, 1)

        controller.testingFinishAssistantResponse("hello")
        controller.hide()
    }

    func testRuntimeStepCodePreviewShowsScrollableCodeBlock() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 0, height: 0),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        let code = Array(repeating: "<button>7</button>", count: 40).joined(separator: "\n")
        controller.testingApplyRuntimeStep(
            AskRuntimeStepEvent(
                id: "tool-write-1",
                kind: .toolCall,
                title: "正在准备写入文件",
                detail: "我正在生成 index.html 的内容。",
                state: .running,
                codeBlock: AskRuntimeCodeBlockPreview(
                    content: code,
                    languageHint: "html",
                    isStreaming: true
                )
            )
        )

        let preview = controller.testingLatestRuntimeStepCodePreview()
        XCTAssertEqual(preview.text, code)
        XCTAssertGreaterThan(preview.height, 0)
        XCTAssertLessThanOrEqual(preview.height, 72)
        controller.hide()
    }

    func testRuntimeStepStreamingKeepsPanelShrinkableAfterLongCodePreview() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 360, height: 280),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )
        controller.testingResizePanel(to: CGSize(width: 360, height: 280))

        let initialSnapshot = controller.testingComposerMetricsSnapshot()
        let longCodeLine = "body{background:linear-gradient(90deg,#111111 0%,#222222 25%,#333333 50%,#444444 75%,#555555 100%);padding:24px;border-radius:16px;box-shadow:0 0 0 1px rgba(255,255,255,0.08) inset;}"
        let code = Array(repeating: longCodeLine, count: 28).joined(separator: "\n")
        controller.testingApplyRuntimeStep(
            AskRuntimeStepEvent(
                id: "tool-write-resize-1",
                kind: .toolCall,
                title: "正在持续生成很长的前端代码预览",
                detail: "这一步会不断附加较长的代码内容，窗口不应该被内容撑宽，也不应该失去继续缩小的能力。",
                state: .running,
                codeBlock: AskRuntimeCodeBlockPreview(
                    content: code,
                    languageHint: "css",
                    isStreaming: true
                )
            )
        )

        let streamingSnapshot = controller.testingComposerMetricsSnapshot()
        XCTAssertLessThanOrEqual(streamingSnapshot.panelWidth, initialSnapshot.panelWidth + 0.5)

        controller.testingResizePanel(to: CGSize(width: 320, height: 280))
        let shrunkSnapshot = controller.testingComposerMetricsSnapshot()
        XCTAssertLessThanOrEqual(shrunkSnapshot.panelWidth, 320.5)
        controller.hide()
    }

    func testPendingApprovalRendersAsSingleInlineRowAboveComposer() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingSetPendingApprovalState(
            actionID: "approval-inline",
            summary: "等待确认当前任务执行",
            message: "This task wants to modify the current Playground workspace and then open the result."
        )
        let snapshot = controller.testingPendingApprovalLayoutSnapshot()

        XCTAssertTrue(snapshot.isVisible)
        XCTAssertTrue(snapshot.detailHidden)
        XCTAssertTrue(snapshot.previewHidden)
        XCTAssertTrue(snapshot.appearsAboveComposer)
        XCTAssertEqual(snapshot.title, "确认后继续当前任务")
        XCTAssertGreaterThanOrEqual(snapshot.confirmButtonWidth, 56)
        XCTAssertGreaterThanOrEqual(snapshot.cancelButtonWidth, 56)
        controller.hide()
    }

    func testPendingApprovalDecisionPromptsBypassKernelPreparation() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingSetPendingApprovalState(
            actionID: "approval-inline",
            summary: "等待确认当前任务执行",
            message: "This task wants to modify the current Playground workspace."
        )

        XCTAssertTrue(controller.testingShouldBypassKernelPreparation(prompt: "确认"))
        XCTAssertTrue(controller.testingShouldBypassKernelPreparation(prompt: "confirm"))
        XCTAssertTrue(controller.testingShouldBypassKernelPreparation(prompt: "取消"))
        XCTAssertFalse(controller.testingShouldBypassKernelPreparation(prompt: "继续"))
        controller.hide()
    }

    func testVisibleOpenActionsDoNotRefocusAskPanelAfterCompletion() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        XCTAssertFalse(controller.testingShouldRefocusComposer(responseMetadata: ["operator_action": "open_url"]))
        XCTAssertFalse(controller.testingShouldRefocusComposer(responseMetadata: ["latest_tool_name": "open_url"]))
        XCTAssertFalse(controller.testingShouldRefocusComposer(responseMetadata: ["latest_tool_name": "open_path"]))
        XCTAssertFalse(controller.testingShouldRefocusComposer(responseMetadata: ["latest_kernel_capability_id": "browser.open_url"]))
        XCTAssertTrue(controller.testingShouldRefocusComposer(responseMetadata: ["latest_tool_name": "search_web"]))

        controller.hide()
    }

    func testWaitingApprovalCompletionSuppressesVerboseAssistantTranscript() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingStartStreamingTurn(prompt: "帮我做一个计算器")
        controller.testingApplyAssistantDelta(
            delta: "我准备开始执行这个 ASK 任务，并在 Playground 工作区内继续创建目录、写文件、执行必要命令并打开结果。",
            fullText: "我准备开始执行这个 ASK 任务，并在 Playground 工作区内继续创建目录、写文件、执行必要命令并打开结果。"
        )
        controller.testingCompleteResponse(
            AskSessionResponse(
                message: "我准备开始执行这个 ASK 任务，并在 Playground 工作区内继续创建目录、写文件、执行必要命令并打开结果。",
                cards: [],
                metadata: [
                    "agent_state": "waiting_approval",
                    "pending_approval_action_id": "approval-inline"
                ]
            )
        )

        XCTAssertTrue(controller.testingAssistantMessageContents().isEmpty)
        XCTAssertTrue(controller.testingPendingApprovalLayoutSnapshot().isVisible)
        controller.hide()
    }

    func testRuntimeStepsCollapseIntoSingleVisibleStatusRow() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingApplyRuntimeStep(
            AskRuntimeStepEvent(
                id: "plan-exit",
                kind: .planning,
                title: "正在退出规划模式",
                detail: "这一步不应该在 transcript 里堆出第二条状态。",
                state: .running
            )
        )
        controller.testingApplyRuntimeStep(
            AskRuntimeStepEvent(
                id: "write-index",
                kind: .toolCall,
                title: "正在准备写入文件",
                detail: "这一步应该替换前一个活动状态，而不是继续往下堆叠。",
                state: .running
            )
        )
        controller.testingApplyRuntimeStep(
            AskRuntimeStepEvent(
                id: "write-index",
                kind: .toolCall,
                title: "正在准备写入文件",
                detail: "完成后的状态也应该继续复用同一条活动状态。",
                state: .completed
            )
        )

        XCTAssertEqual(controller.testingRuntimeStepTitles(), ["正在准备写入文件"])
        controller.hide()
    }

    func testTaskContinuityMetadataStaysHiddenWithoutLeakingIntoTranscript() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingCompleteResponse(
            AskSessionResponse(
                message: "",
                cards: [],
                metadata: [
                    "active_task_title": "收口 ASK 持续助手 checklist",
                    "active_task_status": "running",
                    "active_task_todo_count": "3",
                    "active_task_todo_completed_count": "1",
                    "active_task_todo_in_progress_count": "1",
                    "active_task_todo_open_count": "2",
                    "active_task_progress_summary": "1/3 completed, 1 in progress, 1 pending",
                    "active_task_todo_summary": "[x] 收口 runtime truth\n[-] 打通 MCP live bridge\n[ ] 接上 task continuity surface",
                    "kernel_child_task_count": "2",
                    "kernel_open_child_task_count": "1",
                    "kernel_waiting_task_count": "1",
                    "latest_kernel_child_task_title": "整理 MCP connection diagnostics"
                ]
            )
        )

        let snapshot = controller.testingTaskContinuitySnapshot()
        XCTAssertFalse(snapshot.isVisible)
        XCTAssertTrue(controller.testingAssistantMessageContents().isEmpty)
        controller.hide()
    }

    func testScopeBarStaysHiddenOnMinimalAskSurface() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari",
            initialKernelMetadata: [
                "workspace_root": "/Users/wangjingwen/Desktop/Coding/NexHub-main",
                "current_page_url": "https://github.com/ArvenWang/NexHub",
                "current_page_title": "NexHub Repository",
                "selection_preview": "整理 ASK 持续会话 surface",
                "plan_mode_active": "true",
                "plan_mode_summary": "read-only review",
                "workspace_permission_profile": "workspace_writes_and_shell_execution",
                "workspace_git_write_granted": "true",
                "workspace_network_access_granted": "true",
                "interactive_task_scope_granted": "true",
                "interactive_task_scope_root": "/Users/wangjingwen/Library/Application Support/NexHub/AskPlayground/Tasks/20260403-demo",
                "active_task_title": "收口 session / permission surface"
            ],
            invocationSurface: .askBox
        )

        let snapshot = controller.testingScopeSurfaceSnapshot()
        XCTAssertFalse(snapshot.isVisible)
        controller.hide()
    }

    func testSessionModeCardStaysHiddenOnMinimalAskSurface() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "com.apple.finder",
            sourceAppName: "Finder",
            initialKernelMetadata: [
                "active_task_id": "task-123",
                "active_task_title": "继续 MCP live bridge",
                "active_task_status": "waitingApproval",
                "active_task_resume_token": "task:123",
                "active_task_workspace_root": "/Users/wangjingwen/Desktop/Coding/NexHub-main",
                "workspace_permission_profile": "workspace_writes_and_shell_execution",
                "workspace_git_write_granted": "true",
                "workspace_network_access_granted": "true",
                "latest_assistant_delivery_channel": "inbox"
            ],
            sessionOrigin: .assistantFollowUp,
            invocationSurface: .inbox,
            requestedMode: .interactive
        )

        let snapshot = controller.testingSessionModeSnapshot()
        XCTAssertFalse(snapshot.isVisible)
        controller.hide()
    }

    func testSessionModeCardStaysHiddenEvenWhenAutomationMetadataExists() {
        _ = NSApplication.shared

        let automationStore = makeAutomationStore()
        let parser = AskAutomationDraftParser()
        let now = Date(timeIntervalSinceReferenceDate: 765_432_100)
        let draft = try! XCTUnwrap(parser.parse("每天 9 点检查官网更新", now: now))
        let job = automationStore.createJob(from: draft, now: now)
        let inboxItem = AskInboxItem(
            id: "inbox-automation-1",
            kind: "automation_result",
            title: "官网更新检查",
            summary: "发现了新的更新",
            createdAt: now,
            sourceJobID: job.id,
            sourceRunID: "run-1",
            sourceTaskID: nil,
            sourceTaskStatus: nil,
            assistantDeliveryChannel: "inbox",
            activeTaskID: nil,
            activeTaskResumeToken: nil,
            workspaceRoot: job.workspaceRoot,
            actions: [],
            isRead: false
        )
        automationStore.saveInboxItem(inboxItem)

        let controller = AskConversationWindowController(
            automationStore: automationStore
        )
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingCompleteResponse(
            AskSessionResponse(
                message: "",
                cards: [],
                metadata: [
                    "saved_automation_job_id": job.id,
                    "inbox_item_id": inboxItem.id
                ]
            )
        )

        let snapshot = controller.testingSessionModeSnapshot()
        XCTAssertFalse(snapshot.isVisible)
        controller.hide()
    }

    func testSupplementaryChromeRemainsHiddenForFollowUpContext() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari",
            initialKernelMetadata: [
                "workspace_root": "/Users/wangjingwen/Desktop/Coding/NexHub-main",
                "current_page_url": "https://github.com/ArvenWang/NexHub",
                "current_page_title": "NexHub Repository",
                "active_task_id": "task-123",
                "active_task_title": "继续精简 ASK",
                "active_task_status": "waitingApproval",
                "active_task_resume_token": "task:123",
                "kernel_open_child_task_count": "1",
                "kernel_waiting_task_count": "1"
            ],
            sessionOrigin: .assistantFollowUp,
            invocationSurface: .inbox,
            requestedMode: .interactive
        )

        let taskSnapshot = controller.testingTaskContinuitySnapshot()
        let sessionSnapshot = controller.testingSessionModeSnapshot()
        let scopeSnapshot = controller.testingScopeSurfaceSnapshot()

        XCTAssertFalse(taskSnapshot.isVisible)
        XCTAssertFalse(sessionSnapshot.isVisible)
        XCTAssertFalse(scopeSnapshot.isVisible)
        controller.hide()
    }

    func testPersistentAskSessionRestoresMessagesAndDraftAfterHide() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController(
            assistantFollowUpSessionStore: makeAssistantFollowUpSessionStore(),
            persistentAskSessionCoordinator: makeAskPersistentSessionCoordinator()
        )
        controller.beginPersistentAskSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari",
            invocationSurface: .askBox
        )
        let initialSessionID = controller.testingCurrentSessionID()
        controller.testingStartStreamingTurn(prompt: "先开始一个持续会话")
        controller.testingApplyAssistantDelta(delta: "第一次回答", fullText: "第一次回答")
        controller.testingFinishAssistantResponse("第一次回答")
        controller.testingSetComposerText("继续这个会话")
        controller.hide()

        controller.beginPersistentAskSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "com.apple.finder",
            sourceAppName: "Finder",
            invocationSurface: .askWindow
        )

        XCTAssertTrue(controller.testingIsUsingPersistentAskSessionShell())
        XCTAssertEqual(controller.testingCurrentSessionID(), initialSessionID)
        XCTAssertTrue(controller.testingStateMessageContents().contains(where: { $0.contains("第一次回答") }))
        XCTAssertEqual(controller.testingComposerText(), "继续这个会话")
        XCTAssertGreaterThanOrEqual(controller.testingPersistentAskInvocationCount(), 2)
        controller.hide()
    }

    func testPersistentAskSessionStartsFreshWhenOnlyHistoricalTranscriptExists() {
        _ = NSApplication.shared

        let persistentCoordinator = makeAskPersistentSessionCoordinator()
        let controller = AskConversationWindowController(
            assistantFollowUpSessionStore: makeAssistantFollowUpSessionStore(),
            persistentAskSessionCoordinator: persistentCoordinator
        )
        controller.beginPersistentAskSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari",
            invocationSurface: .askBox
        )
        let originalSessionID = controller.testingCurrentSessionID()
        controller.testingStartStreamingTurn(prompt: "先开始一个短会话")
        controller.testingApplyAssistantDelta(delta: "第一次回答", fullText: "第一次回答")
        controller.testingFinishAssistantResponse("第一次回答")
        controller.hide()

        controller.beginPersistentAskSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "com.apple.finder",
            sourceAppName: "Finder",
            invocationSurface: .askWindow
        )

        XCTAssertTrue(controller.testingIsUsingPersistentAskSessionShell())
        XCTAssertNotEqual(controller.testingCurrentSessionID(), originalSessionID)
        XCTAssertTrue(controller.testingStateMessageContents().isEmpty)
        XCTAssertEqual(controller.testingComposerText(), "")
        XCTAssertEqual(persistentCoordinator.currentSnapshot()?.sessionID, originalSessionID)
        controller.hide()
    }

    func testPersistentAskFollowUpAttachesToCurrentSessionAndUpdatesLineage() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController(
            assistantFollowUpSessionStore: makeAssistantFollowUpSessionStore(),
            persistentAskSessionCoordinator: makeAskPersistentSessionCoordinator()
        )
        controller.beginPersistentAskSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )
        let initialSessionID = controller.testingCurrentSessionID()
        controller.testingStartStreamingTurn(prompt: "保留现有历史")
        controller.testingApplyAssistantDelta(delta: "已有历史", fullText: "已有历史")
        controller.testingFinishAssistantResponse("已有历史")

        let activation = AskAssistantFollowUpActivation(
            title: "继续任务",
            summary: "继续 Playground 里的主任务",
            kind: "assistant_update",
            sourceTaskID: "source-task-1",
            activeTaskID: "task-123",
            sourceTaskStatus: "running",
            sourceSessionID: "session-remote",
            sourceJobID: nil,
            sourceRunID: nil,
            resumeToken: "task:123",
            workspaceRoot: "/Users/wangjingwen/Desktop/Coding/NexHub-main",
            deliveryChannel: AskAssistantDeliveryChannel.inbox.rawValue
        )
        controller.beginAssistantFollowUpSession(
            activation: activation,
            frame: CGRect(x: 240, y: 220, width: 560, height: 320)
        )

        XCTAssertEqual(controller.testingCurrentSessionID(), initialSessionID)
        XCTAssertTrue(controller.testingStateMessageContents().contains(where: { $0.contains("已有历史") }))
        XCTAssertEqual(controller.testingKernelMetadataValue(for: "active_task_resume_token"), "task:123")
        XCTAssertEqual(controller.testingKernelMetadataValue(for: "workspace_root"), "/Users/wangjingwen/Desktop/Coding/NexHub-main")
        XCTAssertGreaterThanOrEqual(controller.testingPersistentAskInvocationCount(), 2)
        controller.hide()
    }

    func testPersistentAskCanRestoreLegacyFollowUpSnapshotAsCompatibilityFallback() {
        _ = NSApplication.shared

        let legacyStore = makeAssistantFollowUpSessionStore()
        let persistentCoordinator = makeAskPersistentSessionCoordinator(legacyStore: legacyStore)
        let persistenceKey = "resume:task:compat"
        legacyStore.save(
            AskAssistantFollowUpSessionSnapshot(
                persistenceKey: persistenceKey,
                savedAt: Date(),
                sessionID: "legacy-session",
                sourceBundleID: "com.apple.Safari",
                sourceAppName: "Safari",
                sessionOrigin: .assistantFollowUp,
                invocationSurface: .inbox,
                requestedMode: .interactive,
                frame: AskAssistantFollowUpWindowFrameSnapshot(rect: CGRect(x: 200, y: 180, width: 560, height: 320)),
                kernelMetadata: [
                    "active_task_id": "legacy-task",
                    "active_task_resume_token": "task:compat",
                    "workspace_root": "/Users/wangjingwen/Desktop/Coding/NexHub-main"
                ],
                latestResponseMetadata: [:],
                messages: [
                    AskMessage(role: .assistant, content: "这是旧 follow-up 快照")
                ],
                messageCards: [],
                pendingApproval: nil,
                composerDraft: "从兼容快照恢复"
            )
        )

        let controller = AskConversationWindowController(
            assistantFollowUpSessionStore: legacyStore,
            persistentAskSessionCoordinator: persistentCoordinator
        )
        let activation = AskAssistantFollowUpActivation(
            title: "继续旧任务",
            summary: "从旧快照恢复",
            kind: "assistant_update",
            sourceTaskID: "legacy-task",
            activeTaskID: "legacy-task",
            sourceTaskStatus: "running",
            sourceSessionID: nil,
            sourceJobID: nil,
            sourceRunID: nil,
            resumeToken: "task:compat",
            workspaceRoot: "/Users/wangjingwen/Desktop/Coding/NexHub-main",
            deliveryChannel: AskAssistantDeliveryChannel.inbox.rawValue
        )
        controller.beginAssistantFollowUpSession(
            activation: activation,
            frame: CGRect(x: 240, y: 220, width: 560, height: 320)
        )

        XCTAssertTrue(controller.testingIsUsingPersistentAskSessionShell())
        XCTAssertEqual(controller.testingCurrentSessionID(), "legacy-session")
        XCTAssertTrue(controller.testingAssistantMessageContents().contains("这是旧 follow-up 快照"))
        XCTAssertEqual(controller.testingComposerText(), "从兼容快照恢复")
        XCTAssertEqual(controller.testingKernelMetadataValue(for: "active_task_resume_token"), "task:compat")
        controller.hide()
    }

    func testProactiveAskContactReusesCurrentPersistentSession() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController(
            assistantFollowUpSessionStore: makeAssistantFollowUpSessionStore(),
            persistentAskSessionCoordinator: makeAskPersistentSessionCoordinator()
        )
        controller.beginPersistentAskSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari",
            invocationSurface: .askWindow
        )
        let initialSessionID = controller.testingCurrentSessionID()
        controller.testingStartStreamingTurn(prompt: "先保留一段历史")
        controller.testingApplyAssistantDelta(delta: "已有回答", fullText: "已有回答")
        controller.testingFinishAssistantResponse("已有回答")

        let opportunity = AskProactiveOpportunity(
            id: "proactive-1",
            createdAt: Date(),
            reason: .automationDecision,
            title: "新的自动化结果",
            summary: "有一个新的 ASK 自动化结果，值得继续处理。",
            dedupeKey: "automation:1",
            confidence: 0.9,
            sourceBundleID: nil,
            sourceAppName: nil,
            sessionOrigin: .automation,
            invocationSurface: .proactivePopup,
            requestedMode: .interactive,
            compatibilityPersistenceKey: "task:automation-1",
            suggestedPrompt: "基于最新自动化结果继续处理。",
            metadata: [
                "active_task_id": "automation-task-1",
                "active_task_resume_token": "task:automation-1"
            ]
        )

        controller.presentProactiveAskContact(
            opportunity,
            targetFrame: CGRect(x: 900, y: 580, width: 440, height: 340),
            fallbackFrame: CGRect(x: 900, y: 580, width: 440, height: 340)
        )

        XCTAssertEqual(controller.testingCurrentSessionID(), initialSessionID)
        XCTAssertTrue(controller.testingIsShowingProactivePopup())
        XCTAssertEqual(controller.testingCurrentProactiveHintText(), "有一个新的 ASK 自动化结果，值得继续处理。")
        XCTAssertGreaterThanOrEqual(controller.testingPersistentAskInvocationCount(), 2)
        controller.hide()
    }

    func testRuntimeStepCodePreviewPersistsUntilNewPreviewArrives() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingApplyRuntimeStep(
            AskRuntimeStepEvent(
                id: "write-html",
                kind: .toolCall,
                title: "正在创建 HTML 文件",
                detail: nil,
                state: .running,
                codeBlock: AskRuntimeCodeBlockPreview(
                    content: "<main class=\"shell\"></main>",
                    languageHint: "html",
                    isStreaming: true
                )
            )
        )
        controller.testingApplyRuntimeStep(
            AskRuntimeStepEvent(
                id: "write-css-status",
                kind: .toolCall,
                title: "正在创建 CSS 文件",
                detail: nil,
                state: .running,
                codeBlock: nil
            )
        )

        let preservedPreview = controller.testingLatestVisibleRuntimeStepCodePreview()
        XCTAssertEqual(preservedPreview.title, "正在创建 CSS 文件")
        XCTAssertTrue((preservedPreview.text ?? "").contains("<main class=\"shell\">"))
        XCTAssertGreaterThan(preservedPreview.height, 0)

        controller.testingApplyRuntimeStep(
            AskRuntimeStepEvent(
                id: "write-js",
                kind: .toolCall,
                title: "正在创建 JavaScript 文件",
                detail: nil,
                state: .running,
                codeBlock: AskRuntimeCodeBlockPreview(
                    content: "const digits = ['7', '8', '9'];",
                    languageHint: "js",
                    isStreaming: true
                )
            )
        )

        let latestPreview = controller.testingLatestVisibleRuntimeStepCodePreview()
        XCTAssertEqual(latestPreview.title, "正在创建 JavaScript 文件")
        XCTAssertTrue((latestPreview.text ?? "").contains("const digits"))
        controller.hide()
    }

    func testAutomationIntentStartsNormalAskTurnWithoutSupplementarySessionChrome() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController(
            automationStore: makeAutomationStore()
        )
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 0, height: 0),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingSetComposerText("每天 9 点帮我检查 OpenAI 官网更新，有变化就告诉我")
        controller.submitCurrentPrompt()

        XCTAssertTrue(controller.testingIsStreaming())
        XCTAssertFalse(controller.testingHasSupplementarySessionChrome())
        XCTAssertFalse(controller.testingHasSaveAutomationButton())
        XCTAssertFalse(controller.testingIsAutomationDraftVisible())
        controller.hide()
    }

    func testAutomationIntentClickingSendKeepsAskSurfaceUnchanged() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController(
            automationStore: makeAutomationStore()
        )
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 0, height: 0),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingSetComposerText("每天 9 点帮我检查 OpenAI 官网更新，有变化就告诉我")
        controller.testingClickSendButtonWhileComposerIsFocused()

        XCTAssertTrue(controller.testingIsStreaming())
        XCTAssertFalse(controller.testingHasSupplementarySessionChrome())
        XCTAssertFalse(controller.testingHasSaveAutomationButton())
        XCTAssertFalse(controller.testingIsAutomationDraftVisible())
        controller.hide()
    }

    func testAskWindowCanStartDragFromHeaderOnly() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 0, height: 0),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        XCTAssertTrue(controller.testingCanStartWindowDragFromHeader())
        XCTAssertFalse(controller.testingCanStartWindowDragFromCloseButton())
        XCTAssertFalse(controller.testingCanStartWindowDragFromComposer())
        controller.hide()
    }

    func testAskPanelUsesTaskConsoleVisualStyle() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari"
        )

        controller.testingStartStreamingTurn(prompt: "继续精简 ASK")
        controller.testingCompleteResponse(
            AskSessionResponse(
                message: "",
                cards: [],
                metadata: [
                    "workspace_root": "/Users/wangjingwen/Desktop/Coding/NexHub-main",
                    "current_page_url": "https://github.com/ArvenWang/NexHub",
                    "current_page_title": "NexHub Repository",
                    "workspace_permission_profile": "workspace_writes_and_shell_execution",
                    "workspace_git_write_granted": "true",
                    "active_task_title": "收口 ASK visual redesign"
                ]
            )
        )

        let snapshot = controller.testingVisualStyleSnapshot()
        XCTAssertTrue(snapshot.usesAskAmbient)
        XCTAssertFalse(snapshot.supplementaryChromeVisible)
        XCTAssertEqual(snapshot.transcriptStageCornerRadius, 0)
        XCTAssertEqual(snapshot.composerCornerRadius, DesignTokens.ConversationPanel.composerCornerRadius)
        XCTAssertGreaterThanOrEqual(snapshot.sendButtonWidth, 60)
        controller.hide()
    }

    func testStreamingHidesCustomScrollIndicatorForCalmerViewport() {
        _ = NSApplication.shared

        let controller = AskConversationWindowController()
        controller.beginNewSession(
            frame: CGRect(x: 240, y: 220, width: 560, height: 320),
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: "nexhub.tests",
            sourceAppName: "Tests"
        )

        controller.testingStartStreamingTurn(prompt: "继续生成")
        controller.testingApplyAssistantDelta(
            delta: Array(repeating: "streaming viewport console ", count: 20).joined(),
            fullText: Array(repeating: "streaming viewport console ", count: 20).joined()
        )

        let snapshot = controller.testingVisualStyleSnapshot()
        XCTAssertTrue(snapshot.scrollIndicatorHidden)
        controller.hide()
    }

    private func makeAutomationStore(file: StaticString = #filePath, line: UInt = #line) -> AskAutomationStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create automation store root: \(error)", file: file, line: line)
        }
        return AskAutomationStore(
            fileManager: .default,
            notificationCenter: NotificationCenter(),
            rootDirectoryURL: root
        )
    }

    private func makeAssistantFollowUpSessionStore(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AskAssistantFollowUpSessionStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create follow-up session store root: \(error)", file: file, line: line)
        }
        return AskAssistantFollowUpSessionStore(
            fileManager: .default,
            rootDirectoryURL: root
        )
    }

    private func makeAskPersistentSessionCoordinator(
        legacyStore: AskAssistantFollowUpSessionStore? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AskPersistentSessionCoordinator {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create persistent ASK session store root: \(error)", file: file, line: line)
        }
        let store = AskPersistentSessionStore(
            fileManager: .default,
            rootDirectoryURL: root
        )
        return AskPersistentSessionCoordinator(
            store: store,
            legacyAssistantFollowUpSessionStore: legacyStore ?? makeAssistantFollowUpSessionStore(file: file, line: line)
        )
    }

    private func responseChunks(from text: String, chunkSize: Int) -> [String] {
        guard chunkSize > 0 else { return [text] }

        var chunks: [String] = []
        var buffer = ""
        buffer.reserveCapacity(chunkSize)

        for character in text {
            buffer.append(character)
            if buffer.count >= chunkSize {
                chunks.append(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            chunks.append(buffer)
        }
        return chunks
    }
}
