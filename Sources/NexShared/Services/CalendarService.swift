import EventKit
import AppKit

extension Notification.Name {
    package static var productCalendarActivityDidChange: Notification.Name {
        AppBrand.productNotificationName("calendarActivityDidChange")
    }
}

package struct CalendarEventIntent: Codable {
    package let title: String
    package let date: String?
    package let time: String?
    package let endTime: String?
    package let allDay: Bool?
    package let durationMinutes: Int?
    package let reminderMinutes: Int?
    package let notes: String?
    package let sourceText: String?
    package let timeText: String?
    package let confidence: Double?
    package let needsConfirmation: Bool?
    package let missingFields: [String]?

    enum CodingKeys: String, CodingKey {
        case title
        case date
        case time
        case endTime = "end_time"
        case allDay = "all_day"
        case durationMinutes = "duration_minutes"
        case reminderMinutes = "reminder_minutes"
        case notes
        case sourceText = "source_text"
        case timeText = "time_text"
        case confidence
        case needsConfirmation = "needs_confirmation"
        case missingFields = "missing_fields"
    }

    package var resolvedStartDate: Date? {
        guard let date, !date.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let time, !time.isEmpty {
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.date(from: "\(date) \(time)")
        }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date)
    }

    package var displayDateString: String {
        guard let startDate = resolvedStartDate else {
            return date ?? L10n.text(zhHans: "待补充日期", en: "Date needed")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppSettings.shared.appLanguage.localeIdentifier)
        if allDay == true || time == nil || time?.isEmpty == true {
            formatter.setLocalizedDateFormatFromTemplate("M d EEEE")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("M d EEEE HH:mm")
        }
        return formatter.string(from: startDate)
    }

    package var isAllDayResolved: Bool {
        allDay == true || time?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    package var displayScheduleSummary: String {
        let base = displayDateString
        if isAllDayResolved {
            return L10n.format(zhHans: "%@ 全天", en: "%@ · All day", base)
        }
        return base
    }

    package var reminderSummary: String {
        let minutes = reminderMinutes ?? (isAllDayResolved ? 480 : 15)
        if minutes == 0 {
            return L10n.text(zhHans: "到时提醒", en: "Remind at time")
        }
        guard minutes > 0 else { return L10n.text(zhHans: "不提醒", en: "No reminder") }
        if minutes % 60 == 0, minutes >= 60 {
            return L10n.format(zhHans: "提前%d小时提醒", en: "Remind %d hour(s) earlier", minutes / 60)
        }
        return L10n.format(zhHans: "提前%d分钟提醒", en: "Remind %d minute(s) earlier", minutes)
    }

    package var creationConfirmationText: String {
        L10n.format(zhHans: "✅ 已创建「%@」 · %@ · %@", en: "✅ Created “%@” · %@ · %@", title, displayScheduleSummary, reminderSummary)
    }
}

package struct CalendarCreatedItemReceipt: Codable, Equatable {
    package enum Kind: String, Codable {
        case event
        case reminder
    }

    package let kind: Kind
    package let title: String
    package let date: String?
    package let time: String?
    package let allDay: Bool?
    package let sourceText: String?
    package let createdAt: Date
    package let calendarTitle: String?
    package let eventIdentifier: String?
    package let externalIdentifier: String?

    package var resolvedStartDate: Date? {
        CalendarEventIntent(
            title: title,
            date: date,
            time: time,
            endTime: nil,
            allDay: allDay,
            durationMinutes: nil,
            reminderMinutes: nil,
            notes: nil,
            sourceText: sourceText,
            timeText: nil,
            confidence: nil,
            needsConfirmation: nil,
            missingFields: nil
        ).resolvedStartDate
    }

    package var isAllDayResolved: Bool {
        allDay == true || time?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    package static func from(
        intent: CalendarEventIntent,
        kind: Kind,
        createdAt: Date = Date(),
        calendarTitle: String? = nil,
        eventIdentifier: String? = nil,
        externalIdentifier: String? = nil
    ) -> CalendarCreatedItemReceipt {
        CalendarCreatedItemReceipt(
            kind: kind,
            title: intent.title,
            date: intent.date,
            time: intent.time,
            allDay: intent.allDay,
            sourceText: intent.sourceText,
            createdAt: createdAt,
            calendarTitle: calendarTitle,
            eventIdentifier: eventIdentifier,
            externalIdentifier: externalIdentifier
        )
    }
}

package enum CalendarService {
    private static let store = EKEventStore()
    private static let permissionManager = PermissionManager()
    private static let calendar = Calendar.current
    private static let calendarBundleID = "com.apple.iCal"
    private static let appleScriptMonths = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december"
    ]

    package static func createEvent(from intent: CalendarEventIntent, revealInCalendar: Bool = false, completion: ((Bool) -> Void)? = nil) {
        DiagnosticsLogger.shared.log("calendar", "createEvent called for: \(intent.title) date=\(intent.date ?? "nil") time=\(intent.time ?? "nil")")
        if revealInCalendar {
            let startedAt = Date()
            DiagnosticsLogger.shared.log("calendar", "createEvent path=appleScript_reveal title=\(intent.title)")
            DispatchQueue.main.async {
                createEventViaAppleScript(intent: intent, revealInCalendar: true) { success in
                    if success {
                        let elapsed = String(format: "%.3f", Date().timeIntervalSince(startedAt))
                        DiagnosticsLogger.shared.log("calendar", "appleScript reveal success title=\(intent.title) elapsed=\(elapsed)s")
                        completion?(true)
                        return
                    }
                    DiagnosticsLogger.shared.log("calendar", "appleScript reveal failed, falling back to EventKit title=\(intent.title)")
                    createEventViaEventKit(intent: intent, revealInCalendar: true, completion: completion)
                }
            }
            return
        }
        createEventViaEventKit(intent: intent, revealInCalendar: false, completion: completion)
    }

    package static func deleteItem(matching receipt: CalendarCreatedItemReceipt, completion: ((Bool) -> Void)? = nil) {
        DiagnosticsLogger.shared.log(
            "calendar",
            "deleteItem called for: \(receipt.title) date=\(receipt.date ?? "nil") time=\(receipt.time ?? "nil") kind=\(receipt.kind.rawValue)"
        )
        requestAccess { granted in
            DiagnosticsLogger.shared.log("calendar", "deleteItem EventKit access granted=\(granted)")
            if granted {
                deleteEventViaEventKit(receipt: receipt) { success in
                    if success {
                        DispatchQueue.main.async { completion?(true) }
                        return
                    }
                    DiagnosticsLogger.shared.log("calendar", "EventKit delete failed, falling back to AppleScript title=\(receipt.title)")
                    DispatchQueue.main.async {
                        deleteEventViaAppleScript(receipt: receipt, completion: completion)
                    }
                }
                return
            }

            DispatchQueue.main.async {
                deleteEventViaAppleScript(receipt: receipt, completion: completion)
            }
        }
    }

    private static func createEventViaEventKit(intent: CalendarEventIntent, revealInCalendar: Bool = false, completion: ((Bool) -> Void)? = nil) {
        requestAccess { granted in
            DiagnosticsLogger.shared.log("calendar", "EventKit access granted=\(granted)")
            guard granted else {
                DiagnosticsLogger.shared.log("calendar", "access denied, falling back to AppleScript")
                DispatchQueue.main.async {
                    createEventViaAppleScript(intent: intent, revealInCalendar: revealInCalendar, completion: completion)
                }
                return
            }

            guard let startDate = intent.resolvedStartDate else {
                DiagnosticsLogger.shared.log("calendar", "failed to parse date: \(intent.date ?? "") \(intent.time ?? "")")
                DispatchQueue.main.async {
                    createEventViaAppleScript(intent: intent, revealInCalendar: revealInCalendar, completion: completion)
                }
                return
            }

            let event = EKEvent(eventStore: store)
            event.title = intent.title

            // Find a writable calendar; prefer default, then first writable
            if let defaultCal = store.defaultCalendarForNewEvents {
                event.calendar = defaultCal
                DiagnosticsLogger.shared.log("calendar", "using default calendar: \(defaultCal.title)")
            } else {
                let writableCals = store.calendars(for: .event).filter { $0.allowsContentModifications }
                if let first = writableCals.first {
                    event.calendar = first
                    DiagnosticsLogger.shared.log("calendar", "default calendar nil, using first writable: \(first.title)")
                } else {
                    DiagnosticsLogger.shared.log("calendar", "no writable calendar found, falling back to AppleScript")
                    DispatchQueue.main.async {
                        createEventViaAppleScript(intent: intent, revealInCalendar: revealInCalendar, completion: completion)
                    }
                    return
                }
            }

            event.startDate = startDate
            let isAllDay = intent.isAllDayResolved
            if isAllDay {
                event.isAllDay = true
                event.endDate = calendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate.addingTimeInterval(86400)
            } else {
                if let endTime = intent.endTime?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !endTime.isEmpty,
                   let eventDate = intent.date,
                   let endDate = resolveExplicitEndDate(date: eventDate, time: endTime) {
                    event.endDate = endDate
                } else if let durationMinutes = intent.durationMinutes, durationMinutes > 0 {
                    event.endDate = startDate.addingTimeInterval(Double(durationMinutes) * 60)
                } else {
                    event.endDate = startDate.addingTimeInterval(3600)
                }
            }

            if let notes = intent.notes, !notes.isEmpty {
                event.notes = notes
            } else if let sourceText = intent.sourceText, !sourceText.isEmpty {
                event.notes = L10n.format(zhHans: "原文：%@", en: "Source: %@", sourceText)
            } else {
                event.notes = L10n.text(zhHans: "由 NexHub 创建", en: "Created by NexHub")
            }

            if let reminderMinutes = intent.reminderMinutes {
                event.addAlarm(EKAlarm(relativeOffset: -Double(reminderMinutes) * 60))
            } else {
                let defaultReminder = isAllDay ? 480 : 15
                event.addAlarm(EKAlarm(relativeOffset: -Double(defaultReminder) * 60))
            }

            do {
                try store.save(event, span: .thisEvent)
                DiagnosticsLogger.shared.log("calendar", "event created via EventKit: \(intent.title) at \(startDate)")
                postCalendarActivity(
                    title: intent.title,
                    summary: intent.creationConfirmationText,
                    metadata: calendarActivityMetadata(
                        id: event.calendarItemExternalIdentifier ?? event.eventIdentifier,
                        kind: .event,
                        title: intent.title,
                        date: intent.date,
                        time: intent.time
                    )
                )
                if revealInCalendar {
                    DispatchQueue.main.async {
                        revealEventInCalendar(event: event, intent: intent)
                    }
                }
                DispatchQueue.main.async { completion?(true) }
            } catch {
                DiagnosticsLogger.shared.log("calendar", "EventKit save failed: \(error.localizedDescription), trying AppleScript")
                DispatchQueue.main.async {
                    createEventViaAppleScript(intent: intent, revealInCalendar: revealInCalendar, completion: completion)
                }
            }
        }
    }

    private static func deleteEventViaEventKit(
        receipt: CalendarCreatedItemReceipt,
        completion: @escaping (Bool) -> Void
    ) {
        guard let event = matchingEvent(for: receipt) else {
            DiagnosticsLogger.shared.log("calendar", "delete EventKit failed to find matching event title=\(receipt.title)")
            completion(false)
            return
        }

        do {
            try store.remove(event, span: .thisEvent)
            DiagnosticsLogger.shared.log("calendar", "deleted event via EventKit title=\(receipt.title)")
            postCalendarActivity(
                title: receipt.title,
                summary: L10n.format(zhHans: "已删除「%@」", en: "Deleted “%@”", receipt.title),
                metadata: calendarActivityMetadata(
                    id: receipt.externalIdentifier ?? receipt.eventIdentifier,
                    kind: receipt.kind,
                    title: receipt.title,
                    date: receipt.date,
                    time: receipt.time
                )
            )
            completion(true)
        } catch {
            DiagnosticsLogger.shared.log("calendar", "EventKit delete failed: \(error.localizedDescription)")
            completion(false)
        }
    }

    private static func matchingEvent(for receipt: CalendarCreatedItemReceipt) -> EKEvent? {
        if let eventIdentifier = receipt.eventIdentifier,
           let event = store.event(withIdentifier: eventIdentifier) {
            return event
        }

        guard let startDate = receipt.resolvedStartDate else {
            return nil
        }

        let searchWindow = eventSearchWindow(for: receipt, startDate: startDate)
        let candidateCalendars: [EKCalendar]?
        if let calendarTitle = receipt.calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !calendarTitle.isEmpty {
            let matchingCalendars = store.calendars(for: .event).filter { $0.title == calendarTitle }
            candidateCalendars = matchingCalendars.isEmpty ? nil : matchingCalendars
        } else {
            candidateCalendars = nil
        }

        let predicate = store.predicateForEvents(
            withStart: searchWindow.start,
            end: searchWindow.end,
            calendars: candidateCalendars
        )
        let normalizedTitle = receipt.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = store.events(matching: predicate).filter { event in
            event.title.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTitle
        }

        return candidates.sorted { lhs, rhs in
            if let externalIdentifier = receipt.externalIdentifier, !externalIdentifier.isEmpty {
                let lhsMatch = lhs.calendarItemExternalIdentifier == externalIdentifier
                let rhsMatch = rhs.calendarItemExternalIdentifier == externalIdentifier
                if lhsMatch != rhsMatch {
                    return lhsMatch && !rhsMatch
                }
            }

            let lhsDistance = abs(lhs.startDate.timeIntervalSince(startDate))
            let rhsDistance = abs(rhs.startDate.timeIntervalSince(startDate))
            if abs(lhsDistance - rhsDistance) > 0.5 {
                return lhsDistance < rhsDistance
            }

            let lhsModified = lhs.lastModifiedDate ?? .distantPast
            let rhsModified = rhs.lastModifiedDate ?? .distantPast
            if lhsModified != rhsModified {
                return lhsModified > rhsModified
            }

            return lhs.calendarItemIdentifier > rhs.calendarItemIdentifier
        }.first
    }

    private static func eventSearchWindow(
        for receipt: CalendarCreatedItemReceipt,
        startDate: Date
    ) -> (start: Date, end: Date) {
        if receipt.isAllDayResolved {
            let dayStart = calendar.startOfDay(for: startDate)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
            return (dayStart, nextDay)
        }
        return (
            startDate.addingTimeInterval(-7_200),
            startDate.addingTimeInterval(7_200)
        )
    }

    // MARK: - AppleScript Fallback

    private static func createEventViaAppleScript(intent: CalendarEventIntent, revealInCalendar: Bool, completion: ((Bool) -> Void)?) {
        guard let startDate = intent.resolvedStartDate else {
            DiagnosticsLogger.shared.log("calendar", "AppleScript fallback: no valid date, opening Calendar app")
            openCalendarApp()
            completion?(false)
            return
        }

        let resolvedAllDay = intent.allDay == true || (intent.time?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let endDate: Date
        if resolvedAllDay {
            endDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate) ?? startDate.addingTimeInterval(86400)
        } else if let endTime = intent.endTime?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !endTime.isEmpty,
                  let eventDate = intent.date,
                  let explicitEndDate = resolveExplicitEndDate(date: eventDate, time: endTime) {
            endDate = explicitEndDate
        } else if let durationMinutes = intent.durationMinutes, durationMinutes > 0 {
            endDate = startDate.addingTimeInterval(Double(durationMinutes) * 60)
        } else {
            endDate = startDate.addingTimeInterval(3600)
        }

        let escapedTitle = escapeForAppleScript(intent.title)
        let escapedNotes = escapeForAppleScript(intent.notes ?? L10n.text(zhHans: "由 NexHub 创建", en: "Created by NexHub"))

        let isAllDay = resolvedAllDay ? "true" : "false"
        let alarmMinutes = intent.reminderMinutes ?? (resolvedAllDay ? 480 : 15)
        let revealScript = revealInCalendar ? """
                    show newEvent
        """ : ""

        let startDateScript = appleScriptDateExpression(variable: "eventStartDate", date: startDate)
        let endDateScript = appleScriptDateExpression(variable: "eventEndDate", date: endDate)

        // Build date objects from components to avoid locale-dependent date parsing.
        let script = """
        tell application "Calendar"
            if (count of calendars) > 0 then
                \(startDateScript)
                \(endDateScript)
                tell calendar 1
                    set newEvent to make new event with properties {summary:"\(escapedTitle)", start date:eventStartDate, end date:eventEndDate, description:"\(escapedNotes)"}
                    set allday event of newEvent to \(isAllDay)
                    tell newEvent
                        if \(alarmMinutes) >= 0 then
                            make new display alarm at end of display alarms with properties {trigger interval:-\(alarmMinutes)}
                        end if
                    end tell
                    \(revealScript)
                end tell
            end if
            activate
        end tell
        """

        DiagnosticsLogger.shared.log("calendar", "running AppleScript for: \(intent.title)")

        DispatchQueue.global(qos: .userInitiated).async {
            var success = false

            if let appleScript = NSAppleScript(source: script) {
                var errorDict: NSDictionary?
                appleScript.executeAndReturnError(&errorDict)
                if errorDict == nil {
                    success = true
                    DiagnosticsLogger.shared.log("calendar", "event created via AppleScript: \(intent.title)")
                    postCalendarActivity(
                        title: intent.title,
                        summary: intent.creationConfirmationText,
                        metadata: calendarActivityMetadata(
                            id: nil,
                            kind: .event,
                            title: intent.title,
                            date: intent.date,
                            time: intent.time
                        )
                    )
                } else {
                    DiagnosticsLogger.shared.log("calendar", "AppleScript failed: \(errorDict ?? [:])")
                }
            }

            DispatchQueue.main.async {
                if !success {
                    DiagnosticsLogger.shared.log("calendar", "all methods failed, just opening Calendar app")
                    openCalendarApp()
                }
                completion?(success)
            }
        }
    }

    private static func openCalendarApp() {
        let calendarURL = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        NSWorkspace.shared.open(calendarURL)
    }

    private static func deleteEventViaAppleScript(
        receipt: CalendarCreatedItemReceipt,
        completion: ((Bool) -> Void)?
    ) {
        guard let startDate = receipt.resolvedStartDate else {
            DiagnosticsLogger.shared.log("calendar", "AppleScript delete: no valid start date for \(receipt.title)")
            completion?(false)
            return
        }

        let escapedTitle = escapeForAppleScript(receipt.title)
        let escapedCalendarTitle = escapeForAppleScript(receipt.calendarTitle ?? "")
        let targetDateScript = appleScriptDateExpression(variable: "targetDate", date: startDate)
        let script = """
        tell application "Calendar"
            \(targetDateScript)
            if "\(escapedCalendarTitle)" is not "" and (exists calendar "\(escapedCalendarTitle)") then
                tell calendar "\(escapedCalendarTitle)"
                    set matchedEvents to (every event whose summary is "\(escapedTitle)" and start date is targetDate)
                    if (count of matchedEvents) > 0 then
                        delete item 1 of matchedEvents
                        return true
                    end if
                end tell
            end if
            repeat with currentCalendar in calendars
                tell currentCalendar
                    set matchedEvents to (every event whose summary is "\(escapedTitle)" and start date is targetDate)
                    if (count of matchedEvents) > 0 then
                        delete item 1 of matchedEvents
                        return true
                    end if
                end tell
            end repeat
            return false
        end tell
        """

        DiagnosticsLogger.shared.log("calendar", "running AppleScript delete for: \(receipt.title)")
        DispatchQueue.global(qos: .userInitiated).async {
            var success = false

            if let appleScript = NSAppleScript(source: script) {
                var errorDict: NSDictionary?
                let result = appleScript.executeAndReturnError(&errorDict)
                if errorDict == nil {
                    success = result.booleanValue
                    DiagnosticsLogger.shared.log("calendar", "delete via AppleScript success=\(success) title=\(receipt.title)")
                    if success {
                        postCalendarActivity(
                            title: receipt.title,
                            summary: L10n.format(zhHans: "已删除「%@」", en: "Deleted “%@”", receipt.title),
                            metadata: calendarActivityMetadata(
                                id: receipt.externalIdentifier ?? receipt.eventIdentifier,
                                kind: receipt.kind,
                                title: receipt.title,
                                date: receipt.date,
                                time: receipt.time
                            )
                        )
                    }
                } else {
                    DiagnosticsLogger.shared.log("calendar", "delete AppleScript failed: \(errorDict ?? [:])")
                }
            }

            DispatchQueue.main.async {
                completion?(success)
            }
        }
    }

    static func openCalendarDraft(for intent: CalendarEventIntent) {
        DiagnosticsLogger.shared.log("calendar", "open draft title=\(intent.title) date=\(intent.date ?? "nil") time=\(intent.time ?? "nil")")
        postCalendarActivity(
            title: intent.title,
            summary: L10n.format(
                zhHans: "已打开「%@」的日历草稿",
                en: "Opened a calendar draft for “%@”",
                intent.title
            ),
            metadata: calendarActivityMetadata(
                id: nil,
                kind: .event,
                title: intent.title,
                date: intent.date,
                time: intent.time
            )
        )
        openCalendarApp()
        activateCalendarApp()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            let opened = postCommandN()
            DiagnosticsLogger.shared.log("calendar", "open draft commandN=\(opened)")
            guard opened else { return }
            let quickEntryText = quickEntryText(for: intent)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                let directWrite = SelectionAccess.writeTextToFocusedWindowField(quickEntryText, sourceBundleID: calendarBundleID)
                DiagnosticsLogger.shared.log("calendar", "open draft focused_window_write success=\(directWrite.success) diagnostics=\(directWrite.diagnostics)")
                if directWrite.success {
                    return
                }
                let injected = postUnicodeText(quickEntryText)
                DiagnosticsLogger.shared.log("calendar", "open draft unicode_injection=\(injected) text=\(quickEntryText)")
            }
        }
    }

    private static func resolveExplicitEndDate(date: String, time: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(date) \(time)")
    }

    private static func revealEventInCalendar(event: EKEvent, intent: CalendarEventIntent) {
        guard let startDate = event.startDate as Date? else {
            openCalendarDraft(for: intent)
            return
        }
        openCalendarApp()

        let startDateScript = appleScriptDateExpression(variable: "targetDate", date: startDate)
        let uid = escapeForAppleScript(event.calendarItemExternalIdentifier ?? "")
        let calendarTitle = escapeForAppleScript(event.calendar.title)
        let title = escapeForAppleScript(intent.title)
        let script = """
        tell application "Calendar"
            activate
            repeat 8 times
                if "\(uid)" is not "" and "\(calendarTitle)" is not "" and (exists calendar "\(calendarTitle)") then
                    tell calendar "\(calendarTitle)"
                        set matchedEvents to (every event whose uid is "\(uid)")
                    end tell
                    if (count of matchedEvents) > 0 then
                        show item 1 of matchedEvents
                        return
                    end if
                end if
                delay 0.12
            end repeat
            \(startDateScript)
            switch view to month view
            view calendar at targetDate
            delay 0.08
            if "\(calendarTitle)" is not "" and (exists calendar "\(calendarTitle)") then
                tell calendar "\(calendarTitle)"
                    set matchedByTitle to (every event whose summary is "\(title)")
                end tell
                if (count of matchedByTitle) > 0 then
                    show item 1 of matchedByTitle
                    return
                end if
            end if
        end tell
        """
        runAppleScript(script, label: "reveal calendar event")
    }

    private static func activateCalendarApp() {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == calendarBundleID }) {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        openCalendarApp()
    }

    private static func quickEntryText(for intent: CalendarEventIntent) -> String {
        let title = intent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = intent.date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let time = intent.time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !date.isEmpty && !time.isEmpty {
            return "\(title) \(date) \(time)"
        }
        if !date.isEmpty {
            return "\(title) \(date)"
        }
        return title
    }

    private static func runAppleScript(_ source: String, label: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let appleScript = NSAppleScript(source: source) else {
                DiagnosticsLogger.shared.log("calendar", "\(label) AppleScript compile failed")
                return
            }
            var errorDict: NSDictionary?
            appleScript.executeAndReturnError(&errorDict)
            if let errorDict {
                DiagnosticsLogger.shared.log("calendar", "\(label) AppleScript failed: \(errorDict)")
            }
        }
    }

    private static func postCommandN() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 45, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 45, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func postUnicodeText(_ text: String) -> Bool {
        guard !text.isEmpty,
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }

        let utf16 = Array(text.utf16)
        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func postCalendarActivity(
        title: String,
        summary: String,
        metadata: [String: String]
    ) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .productCalendarActivityDidChange,
                object: nil,
                userInfo: [
                    "title": title,
                    "summary": summary,
                    "metadata": metadata
                ]
            )
        }
    }

    private static func calendarActivityMetadata(
        id: String?,
        kind: CalendarCreatedItemReceipt.Kind,
        title: String,
        date: String?,
        time: String?
    ) -> [String: String] {
        var metadata: [String: String] = [
            "calendar_activity_kind": kind.rawValue,
            "calendar_item_title": title
        ]
        if let id, !id.isEmpty {
            metadata["calendar_activity_id"] = id
        }
        if let date, !date.isEmpty {
            metadata["calendar_item_date"] = date
        }
        if let time, !time.isEmpty {
            metadata["calendar_item_time"] = time
        }
        return metadata
    }

    // MARK: - Authorization

    private static func requestAccess(completion: @escaping (Bool) -> Void) {
        let status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        DiagnosticsLogger.shared.log("calendar", "current authorization status: \(status.rawValue)")
        permissionManager.requestCalendarAccess { result in
            let errorText = result.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let diagnostic = "permission before=\(PermissionManager.calendarStatusText(result.beforeStatus)) after=\(PermissionManager.calendarStatusText(result.afterStatus)) granted=\(result.granted) detail=\(result.detail)"
            if errorText.isEmpty {
                DiagnosticsLogger.shared.log("calendar", diagnostic)
            } else {
                DiagnosticsLogger.shared.log("calendar", "\(diagnostic) error=\(errorText)")
            }
            completion(result.granted)
        }
    }

    private static func escapeForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func appleScriptDateExpression(variable: String, date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = components.year ?? 1970
        let monthIndex = min(max((components.month ?? 1) - 1, 0), appleScriptMonths.count - 1)
        let monthToken = appleScriptMonths[monthIndex]
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let secondsOfDay = hour * 3600 + minute * 60 + second
        return """
        set \(variable) to (current date)
        set year of \(variable) to \(year)
        set month of \(variable) to \(monthToken)
        set day of \(variable) to \(day)
        set time of \(variable) to \(secondsOfDay)
        """
    }
}
