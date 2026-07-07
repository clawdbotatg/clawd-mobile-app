import Contacts
import EventKit
import Foundation
import MLXLMCommon
import UIKit

/// Tools the on-device model can call to answer questions about the phone.
/// Everything runs locally: iOS shows its normal permission dialog the first
/// time a data source (contacts, calendar) is touched, and the data goes into
/// the local model's context only — never off the device.
///
/// Adding a tool: define Input/Output Codable types + a `Tool`, then list it
/// in `specs` and `dispatch`.
enum PhoneTools {

    // MARK: search_contacts

    struct ContactsInput: Codable {
        let query: String
    }
    struct ContactResult: Codable {
        let name: String
        let phones: [String]
        let emails: [String]
    }

    static let searchContacts = Tool<ContactsInput, [ContactResult]>(
        name: "search_contacts",
        description:
            "Search the user's contacts by name (full or partial). Returns matching contacts with their phone numbers and email addresses.",
        parameters: [
            .required("query", type: .string, description: "Name or partial name to search for")
        ]
    ) { input in
        let store = CNContactStore()
        guard try await store.requestAccess(for: .contacts) else {
            throw ToolFailure.denied("contacts")
        }
        let keys =
            [
                CNContactGivenNameKey, CNContactFamilyNameKey,
                CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            ] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: input.query)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        return contacts.prefix(8).map { contact in
            ContactResult(
                name: "\(contact.givenName) \(contact.familyName)"
                    .trimmingCharacters(in: .whitespaces),
                phones: contact.phoneNumbers.map { $0.value.stringValue },
                emails: contact.emailAddresses.map { $0.value as String }
            )
        }
    }

    // MARK: get_calendar_events

    struct CalendarInput: Codable {
        let days_ahead: Int?
    }
    struct EventResult: Codable {
        let title: String
        let start: String
        let end: String
        let location: String?
        let all_day: Bool
    }

    static let calendarEvents = Tool<CalendarInput, [EventResult]>(
        name: "get_calendar_events",
        description:
            "Get the user's upcoming calendar events, from now through `days_ahead` days (default 7).",
        parameters: [
            .optional(
                "days_ahead", type: .int,
                description: "How many days ahead to look (default 7, max 60)")
        ]
    ) { input in
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw ToolFailure.denied("calendar")
        }
        let start = Date()
        let days = min(max(input.days_ahead ?? 7, 1), 60)
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d, h:mm a"
        return store.events(matching: predicate).prefix(25).map { event in
            EventResult(
                title: event.title ?? "(untitled)",
                start: formatter.string(from: event.startDate),
                end: formatter.string(from: event.endDate),
                location: event.location,
                all_day: event.isAllDay
            )
        }
    }

    // MARK: get_device_status

    struct DeviceStatusInput: Codable {}
    struct DeviceStatus: Codable {
        let battery_percent: Int
        let battery_state: String
        let ios_version: String
        let current_date_time: String
    }

    static let deviceStatus = Tool<DeviceStatusInput, DeviceStatus>(
        name: "get_device_status",
        description:
            "Get the phone's battery level and charging state, iOS version, and the current date and time.",
        parameters: []
    ) { _ in
        await MainActor.run {
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            let state: String =
                switch device.batteryState {
                case .charging: "charging"
                case .full: "full"
                case .unplugged: "on battery"
                default: "unknown"
                }
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE MMM d yyyy, h:mm a"
            return DeviceStatus(
                battery_percent: Int(device.batteryLevel * 100),
                battery_state: state,
                ios_version: device.systemVersion,
                current_date_time: formatter.string(from: Date())
            )
        }
    }

    // MARK: wiring

    static var specs: [ToolSpec] {
        [searchContacts.schema, calendarEvents.schema, deviceStatus.schema]
    }

    /// Execute a tool call from the model, returning JSON for the tool-result
    /// message. Errors come back as `{"error": …}` so the model can explain
    /// the failure instead of the whole generation aborting.
    static func dispatch(_ call: ToolCall) async -> String {
        do {
            switch call.function.name {
            case searchContacts.name:
                return try encode(await call.execute(with: searchContacts))
            case calendarEvents.name:
                return try encode(await call.execute(with: calendarEvents))
            case deviceStatus.name:
                return try encode(await call.execute(with: deviceStatus))
            default:
                return #"{"error": "unknown tool '\#(call.function.name)'"}"#
            }
        } catch {
            return #"{"error": "\#(error.localizedDescription)"}"#
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "{}"
    }

    enum ToolFailure: LocalizedError {
        case denied(String)
        var errorDescription: String? {
            switch self {
            case .denied(let source):
                "The user has not granted access to \(source). They can enable it in Settings."
            }
        }
    }
}
