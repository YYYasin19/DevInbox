import SwiftUI

/// How absolute dates are written: older dates in rows ("Mar 18", "18.03.26") and exact times in
/// tooltips. Recent dates stay relative ("3d") in every style.
enum DateFormat: String, CaseIterable, Identifiable {
    case monthDay
    case european
    case iso

    var id: Self { self }

    var label: String {
        switch self {
        case .monthDay: "Month and day (Mar 18)"
        case .european: "European (18.03.26)"
        case .iso: "ISO (2026-03-18)"
        }
    }

    /// A date too old for a relative age.
    func day(_ date: Date, relativeTo now: Date) -> String {
        switch self {
        case .monthDay:
            let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).year())
        case .european: return Self.europeanDay.string(from: date)
        case .iso: return Self.isoDay.string(from: date)
        }
    }

    /// An exact moment, for tooltips.
    func timestamp(_ date: Date) -> String {
        switch self {
        case .monthDay: date.formatted(date: .abbreviated, time: .shortened)
        case .european: Self.europeanTimestamp.string(from: date)
        case .iso: Self.isoTimestamp.string(from: date)
        }
    }

    private static let europeanDay = fixed("dd.MM.yy")
    private static let isoDay = fixed("yyyy-MM-dd")
    private static let europeanTimestamp = fixed("dd.MM.yy, HH:mm")
    private static let isoTimestamp = fixed("yyyy-MM-dd HH:mm")

    private static func fixed(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}

extension EnvironmentValues {
    @Entry var dateFormat: DateFormat = .monthDay
    /// Ticks once a minute, for relative times like "5m".
    @Entry var now: Date = .now
}
