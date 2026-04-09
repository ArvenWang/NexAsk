import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskAutomationDraftParserTests: XCTestCase {
    private let parser = AskAutomationDraftParser()

    func testParsesDailyAutomationRule() {
        let draft = parser.parse("每天 9 点帮我检查 OpenAI 官网更新，有变化就告诉我", now: referenceDate())

        XCTAssertEqual(draft?.trigger.kind, .dailyAt)
        XCTAssertEqual(draft?.trigger.hour, 9)
        XCTAssertEqual(draft?.trigger.minute, 0)
        XCTAssertEqual(draft?.normalizedTaskPrompt, "检查 OpenAI 官网更新，有变化就告诉我")
    }

    func testParsesWeeklyAutomationRule() {
        let draft = parser.parse("每周一上午 10 点整理下载文件夹里的 PDF，并写个总结到知识库", now: referenceDate())

        XCTAssertEqual(draft?.trigger.kind, .weekly)
        XCTAssertEqual(draft?.trigger.weekday, 2)
        XCTAssertEqual(draft?.trigger.hour, 10)
        XCTAssertEqual(draft?.trigger.minute, 0)
        XCTAssertEqual(draft?.normalizedTaskPrompt, "整理下载文件夹里的 PDF，并写个总结到知识库")
    }

    func testParsesEveryNHoursAutomationRule() {
        let draft = parser.parse("每隔 6 小时检查一次官网更新", now: referenceDate())

        XCTAssertEqual(draft?.trigger.kind, .everyNHours)
        XCTAssertEqual(draft?.trigger.intervalHours, 6)
        XCTAssertEqual(draft?.normalizedTaskPrompt, "检查一次官网更新")
    }

    func testParsesTonightAutomationRule() throws {
        let draft = parser.parse("今晚 8 点提醒我把这篇网页采集进知识库", now: referenceDate())

        XCTAssertEqual(draft?.trigger.kind, .onceAt)
        XCTAssertNotNil(draft?.trigger.absoluteDate)
        XCTAssertEqual(Calendar.current.component(.hour, from: try XCTUnwrap(draft?.trigger.absoluteDate)), 20)
        XCTAssertEqual(draft?.normalizedTaskPrompt, "提醒我把这篇网页采集进知识库")
    }

    func testParsesRelativeMinuteAutomationRule() throws {
        let draft = parser.parse("1分钟后帮我打开B站", now: referenceDate())

        XCTAssertEqual(draft?.trigger.kind, .onceAt)
        let date = try XCTUnwrap(draft?.trigger.absoluteDate)
        XCTAssertEqual(Int(date.timeIntervalSince(referenceDate())), 60)
        XCTAssertEqual(draft?.normalizedTaskPrompt, "打开B站")
        XCTAssertTrue(draft?.keyToolDomains.contains("web") == true)
    }

    func testDetectsRelativeMinuteAutomationIntent() {
        XCTAssertTrue(parser.detectsAutomationIntent(in: "10分钟后去网上搜最新金价告诉我"))
    }

    func testParsesMonthlyAutomationRule() {
        let draft = parser.parse("每月 1 号早上 9 点整理上个月的项目进展", now: referenceDate())

        XCTAssertEqual(draft?.trigger.kind, .monthlyDay)
        XCTAssertEqual(draft?.trigger.day, 1)
        XCTAssertEqual(draft?.trigger.hour, 9)
        XCTAssertEqual(draft?.trigger.minute, 0)
        XCTAssertEqual(draft?.normalizedTaskPrompt, "整理上个月的项目进展")
    }

    func testParsesDailyAutomationRuleWithPreambleCleanup() {
        let draft = parser.parse("以后每天 9 点帮我整理昨天的项目更新并同步到知识库", now: referenceDate())

        XCTAssertEqual(draft?.trigger.kind, .dailyAt)
        XCTAssertEqual(draft?.normalizedTaskPrompt, "整理昨天的项目更新并同步到知识库")
    }

    private func referenceDate() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 11, minute: 30)) ?? Date()
    }
}
