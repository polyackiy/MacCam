import SwiftUI

/// Editor for one `WeeklySchedule`: enable toggle, weekday chips, start/end times.
struct ScheduleEditor: View {
    let title: LocalizedStringKey
    @Binding var schedule: WeeklySchedule
    var onChange: () -> Void

    private let order: [(Weekday, LocalizedStringKey)] = [
        (.mon, "Mon"), (.tue, "Tue"), (.wed, "Wed"), (.thu, "Thu"),
        (.fri, "Fri"), (.sat, "Sat"), (.sun, "Sun")]

    var body: some View {
        Section(title) {
            Toggle("Enabled", isOn: Binding(
                get: { schedule.enabled },
                set: { schedule.enabled = $0; onChange() }))
            if schedule.enabled {
                HStack(spacing: 4) {
                    ForEach(order, id: \.0) { day, label in
                        let on = schedule.days.contains(day)
                        Button(action: {
                            if on { schedule.days.remove(day) } else { schedule.days.insert(day) }
                            onChange()
                        }, label: { Text(label).frame(maxWidth: .infinity) })
                        .buttonStyle(.bordered)
                        .tint(on ? .accentColor : .gray)
                    }
                }
                DatePicker("Start", selection: timeBinding(\.start), displayedComponents: .hourAndMinute)
                DatePicker("End", selection: timeBinding(\.end), displayedComponents: .hourAndMinute)
                Text("Overnight windows (start after end) span midnight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func timeBinding(_ keyPath: WritableKeyPath<WeeklySchedule, TimeOfDay>) -> Binding<Date> {
        Binding(
            get: {
                let tod = schedule[keyPath: keyPath]
                return Calendar.current.date(
                    from: DateComponents(hour: tod.hour, minute: tod.minute)) ?? Date()
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                schedule[keyPath: keyPath] = TimeOfDay(minutes: (comps.hour ?? 0) * 60 + (comps.minute ?? 0))
                onChange()
            })
    }
}
