//
//  FlowView.swift
//  Dayflow
//
//  Flow tab, fully native and offline. It replaces the hosted Flow web app:
//  plan tasks, pick a length and alert style, run the session (breaks,
//  check-offs, live activity log), then review the summary and past sessions.
//  Data lives in FlowLocalSessionStore; the screen watching is still done by
//  FlowDistractionAgent with the user's own Codex or Claude CLI.
//

import SwiftUI

struct FlowView: View {
  @Environment(\.dayflowTheme) private var theme
  @ObservedObject private var store = FlowLocalSessionStore.shared
  @ObservedObject private var mirror = FlowSessionMirror.shared
  @ObservedObject private var timeline = FlowSessionTimeline.shared
  @ObservedObject private var agent = FlowDistractionAgent.shared
  /// Read only so a provider change re-renders the gate.
  @AppStorage(LLMProviderRoutingStore.storageKey) private var providerRouting: Data?

  @State private var newTask = ""
  @State private var selectedGoalIDs: Set<String> = []
  @State private var weekCategories: [FlowLocalSessionStore.CategoryMinutes] = []

  private static let durations = [15, 25, 50, 90]
  private static let breakLengths = [5, 10, 15]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        if !FlowDistractionAgent.providerCanWatch {
          providerNotice
        }
        if store.isSessionOn, let session = store.current {
          liveSession(session)
        } else if let summary = store.summarySession {
          summaryCard(summary)
        } else {
          setupCard
        }
        if !store.isSessionOn {
          weekCard
          historyCard
        }
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .task { await refreshWeek() }
    .onChange(of: store.history.count) { Task { await refreshWeek() } }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Flow")
          .font(.custom("InstrumentSerif-Regular", size: 36))
          .foregroundColor(theme.textPrimary)
        Text("Pick what you want done. Flow watches your screen and nudges you when you drift.")
          .font(.custom("Figtree", size: 13))
          .foregroundColor(theme.textSecondary)
      }
      Spacer()
      if store.isSessionOn {
        Text(agent.statusLine)
          .font(.custom("Figtree", size: 11))
          .foregroundColor(theme.textMuted)
          .lineLimit(1)
      }
    }
  }

  private var providerNotice: some View {
    card {
      HStack(spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(Color(hex: "F2994A"))
        VStack(alignment: .leading, spacing: 2) {
          Text("Flow needs ChatGPT (Codex) or Claude as your provider")
            .font(.custom("Figtree", size: 13).weight(.semibold))
            .foregroundColor(theme.textPrimary)
          Text(
            "Screen watching runs through your own codex or claude command line tool. Switch your provider in Settings → Providers."
          )
          .font(.custom("Figtree", size: 12))
          .foregroundColor(theme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  // MARK: - Setup

  private var setupCard: some View {
    card {
      VStack(alignment: .leading, spacing: 16) {
        sectionTitle("Plan your session")
        taskEntryField(placeholder: "Add a task you want to finish…") {
          store.addTask($0, addToSession: false)
          if let last = store.tasks.last { selectedGoalIDs.insert(last.id) }
        }

        if store.openTasks.isEmpty {
          Text("No tasks yet. You can also start without any; Flow will just keep you on task.")
            .font(.custom("Figtree", size: 12))
            .foregroundColor(theme.textMuted)
        } else {
          VStack(spacing: 6) {
            ForEach(store.openTasks) { task in
              setupTaskRow(task)
            }
          }
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
          label("Length")
          HStack(spacing: 8) {
            ForEach(Self.durations, id: \.self) { minutes in
              chip(
                "\(minutes)m",
                selected: !store.defaultAlwaysOn && store.defaultMinutes == minutes
              ) {
                store.defaultAlwaysOn = false
                store.defaultMinutes = minutes
              }
            }
            chip("Always on", selected: store.defaultAlwaysOn) {
              store.defaultAlwaysOn = true
            }
            if !store.defaultAlwaysOn {
              Stepper(
                "\(store.defaultMinutes) min",
                value: Binding(
                  get: { store.defaultMinutes },
                  set: { store.defaultMinutes = $0 }),
                in: 5...240, step: 5
              )
              .font(.custom("Figtree", size: 12))
              .foregroundColor(theme.textSecondary)
              .fixedSize()
            }
          }
        }

        VStack(alignment: .leading, spacing: 8) {
          label("When I drift")
          HStack(spacing: 8) {
            ForEach(FlowAlertStyle.allCases, id: \.self) { style in
              chip(Self.styleTitle(style), selected: store.defaultAlertStyle == style) {
                store.defaultAlertStyle = style
              }
            }
          }
          Text(Self.styleDescription(store.defaultAlertStyle))
            .font(.custom("Figtree", size: 12))
            .foregroundColor(theme.textMuted)
        }

        HStack {
          Spacer()
          primaryButton("Start session", systemImage: "play.fill") {
            store.startSession(
              goalIDs: store.openTasks.map(\.id).filter { selectedGoalIDs.contains($0) },
              minutes: store.defaultAlwaysOn ? nil : store.defaultMinutes,
              alertStyle: store.defaultAlertStyle)
            selectedGoalIDs = []
          }
          .disabled(!FlowDistractionAgent.providerCanWatch)
          .opacity(FlowDistractionAgent.providerCanWatch ? 1 : 0.5)
        }
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(theme.accent, lineWidth: store.setupRequested ? 2 : 0)
    )
    .onAppear {
      if selectedGoalIDs.isEmpty { selectedGoalIDs = Set(store.openTasks.map(\.id)) }
    }
  }

  private func setupTaskRow(_ task: FlowLocalTask) -> some View {
    let selected = selectedGoalIDs.contains(task.id)
    return HStack(spacing: 10) {
      Button {
        if selected { selectedGoalIDs.remove(task.id) } else { selectedGoalIDs.insert(task.id) }
      } label: {
        Image(systemName: selected ? "checkmark.square.fill" : "square")
          .foregroundColor(selected ? theme.accent : theme.textMuted)
      }
      .buttonStyle(.plain)
      .help("Include in this session")
      Text(task.title)
        .font(.custom("Figtree", size: 13))
        .foregroundColor(theme.textPrimary)
      Spacer()
      Button { store.toggleDone(task.id) } label: {
        Image(systemName: "checkmark.circle")
      }
      .buttonStyle(.plain)
      .foregroundColor(theme.textMuted)
      .help("Mark done")
      Button { store.deleteTask(task.id) } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.plain)
      .foregroundColor(theme.textMuted)
      .help("Delete")
    }
    .padding(.vertical, 4)
  }

  // MARK: - Live session

  private func liveSession(_ session: FlowLocalSession) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      card {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          liveHeader(session, now: context.date)
        }
      }

      card {
        VStack(alignment: .leading, spacing: 10) {
          sectionTitle("Tasks")
          let goals = store.tasks.filter { session.goalIDs.contains($0.id) }
          if goals.isEmpty {
            Text("No tasks for this session. Flow is just keeping you on task.")
              .font(.custom("Figtree", size: 12))
              .foregroundColor(theme.textMuted)
          }
          ForEach(goals) { task in
            liveTaskRow(task)
          }
          taskEntryField(placeholder: "Add a task to this session…") {
            store.addTask($0, addToSession: true)
          }
          let others = store.openTasks.filter { !session.goalIDs.contains($0.id) }
          if !others.isEmpty {
            Menu("Add from your list") {
              ForEach(others) { task in
                Button(task.title) { store.toggleGoal(task.id) }
              }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.custom("Figtree", size: 12))
          }
        }
      }

      card {
        VStack(alignment: .leading, spacing: 10) {
          sectionTitle("Activity so far")
          if timeline.entries.isEmpty {
            Text("Flow fills this in about once a minute as it watches.")
              .font(.custom("Figtree", size: 12))
              .foregroundColor(theme.textMuted)
          } else {
            timelineList(timeline.entries)
          }
        }
      }
    }
  }

  private func liveHeader(_ session: FlowLocalSession, now: Date) -> some View {
    let snapshot = mirror.snapshot
    let onBreak = snapshot.phase == .onBreak
    let big: String
    let caption: String
    if onBreak, let breakEnds = snapshot.breakEndsAt {
      big = Self.clock(TimeInterval(breakEnds) - now.timeIntervalSince1970)
      caption = String(localized: "On a break")
    } else if let endsAt = snapshot.sessionEndsAt {
      big = Self.clock(TimeInterval(endsAt) - now.timeIntervalSince1970)
      caption = String(localized: "left in this session")
    } else {
      big = Self.clock(session.elapsed(at: now))
      caption = String(localized: "in flow (always on)")
    }
    return VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(big)
          .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
          .foregroundColor(onBreak ? Color(hex: "5B8DEF") : theme.textPrimary)
        Text(caption)
          .font(.custom("Figtree", size: 13))
          .foregroundColor(theme.textSecondary)
        Spacer()
        if mirror.isDistracted && !onBreak {
          Label("Drifting", systemImage: "exclamationmark.circle.fill")
            .font(.custom("Figtree", size: 12).weight(.semibold))
            .foregroundColor(Color(hex: "E8743B"))
        }
      }
      HStack(spacing: 18) {
        stat("Focused", Self.duration(session.focusedSeconds(at: now)))
        stat("Distracted", Self.duration(session.distractedSeconds(at: now)))
        stat("Drifts", "\(session.distractions.count)")
        stat("Done", "\(session.completedTitles.count)")
        Spacer()
        if onBreak {
          primaryButton("Resume", systemImage: "play.fill") { store.resumeFromBreak() }
        } else {
          Menu {
            ForEach(Self.breakLengths, id: \.self) { minutes in
              Button("\(minutes) minutes") { store.takeBreak(minutes: minutes) }
            }
          } label: {
            Label("Break", systemImage: "cup.and.saucer")
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
        }
        Button(role: .destructive) {
          store.endSession()
        } label: {
          Label("End", systemImage: "stop.fill")
        }
        .buttonStyle(.bordered)
      }
    }
  }

  private func liveTaskRow(_ task: FlowLocalTask) -> some View {
    HStack(spacing: 10) {
      Button { store.toggleDone(task.id) } label: {
        Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
          .foregroundColor(task.isDone ? Color(hex: "3FA66B") : theme.textMuted)
      }
      .buttonStyle(.plain)
      Text(task.title)
        .font(.custom("Figtree", size: 13))
        .strikethrough(task.isDone)
        .foregroundColor(task.isDone ? theme.textMuted : theme.textPrimary)
      if task.completedByFlow {
        Text("checked off by Flow")
          .font(.custom("Figtree", size: 10).weight(.medium))
          .foregroundColor(theme.accent)
      }
      Spacer()
      Button { store.toggleGoal(task.id) } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.plain)
      .foregroundColor(theme.textMuted)
      .help("Remove from this session")
    }
  }

  // MARK: - Summary

  private func summaryCard(_ session: FlowLocalSession) -> some View {
    let end = session.endedAt ?? Date()
    return card {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          sectionTitle(session.endedNaturally ? "Session complete" : "Session ended")
          Spacer()
          Button("Done") { store.dismissSummary() }
            .buttonStyle(.bordered)
          primaryButton("New session", systemImage: "plus") { store.dismissSummary() }
        }
        HStack(spacing: 18) {
          if let score = session.focusScore(at: end) {
            stat("Focus", "\(Int((score * 100).rounded()))%")
          }
          stat("Length", Self.duration(session.elapsed(at: end)))
          stat("Focused", Self.duration(session.focusedSeconds(at: end)))
          stat("Distracted", Self.duration(session.distractedSeconds(at: end)))
          stat("Breaks", Self.duration(session.breakSeconds(at: end)))
        }
        focusBar(session)
        if !session.completedTitles.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            label("Finished")
            ForEach(session.completedTitles, id: \.self) { title in
              Label(title, systemImage: "checkmark.circle.fill")
                .font(.custom("Figtree", size: 13))
                .foregroundColor(theme.textPrimary)
            }
          }
        }
        let unfinished = session.goalTitles.filter { !session.completedTitles.contains($0) }
        if !unfinished.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            label("Still open")
            ForEach(unfinished, id: \.self) { title in
              Label(title, systemImage: "circle")
                .font(.custom("Figtree", size: 13))
                .foregroundColor(theme.textSecondary)
            }
          }
        }
        if !session.timeline.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            label("What happened")
            timelineList(session.timeline)
          }
        }
      }
    }
  }

  /// One horizontal strip: the session from start to end, coloured by what
  /// Flow logged (focused, drifting, break).
  private func focusBar(_ session: FlowLocalSession) -> some View {
    let start = session.startedAt
    let end = session.endedAt ?? Date()
    let total = max(1, end.timeIntervalSince(start))
    func spans(_ intervals: [FlowLocalInterval]) -> [(Double, Double)] {
      intervals.map { interval in
        let from = interval.start.timeIntervalSince(start) / total
        let to = (interval.end ?? end).timeIntervalSince(start) / total
        return (max(0, from), min(1, to))
      }
    }
    return GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(Self.kindColor(.focused))
        ForEach(Array(spans(session.distractions).enumerated()), id: \.offset) { _, span in
          Rectangle().fill(Self.kindColor(.distracted))
            .frame(width: max(2, geo.size.width * (span.1 - span.0)))
            .offset(x: geo.size.width * span.0)
        }
        ForEach(Array(spans(session.breaks).enumerated()), id: \.offset) { _, span in
          Rectangle().fill(Self.kindColor(.`break`))
            .frame(width: max(2, geo.size.width * (span.1 - span.0)))
            .offset(x: geo.size.width * span.0)
        }
      }
      .clipShape(Capsule())
    }
    .frame(height: 10)
  }

  // MARK: - Week & history

  private var weekCard: some View {
    let total = weekCategories.reduce(0) { $0 + $1.minutes }
    let maxMinutes = max(1, weekCategories.map(\.minutes).max() ?? 1)
    return card {
      VStack(alignment: .leading, spacing: 10) {
        sectionTitle("Your last 7 days")
        if total <= 0 {
          Text("Once Dayflow has a few days of timeline, your time by category shows up here.")
            .font(.custom("Figtree", size: 12))
            .foregroundColor(theme.textMuted)
        } else {
          ForEach(weekCategories) { category in
            HStack(spacing: 10) {
              Text(category.name)
                .font(.custom("Figtree", size: 12))
                .foregroundColor(theme.textSecondary)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)
              GeometryReader { geo in
                Capsule()
                  .fill(Color(hex: category.colorHex))
                  .frame(width: max(2, geo.size.width * category.minutes / maxMinutes))
              }
              .frame(height: 8)
              Text(Self.duration(category.minutes * 60))
                .font(.custom("Figtree", size: 12).monospacedDigit())
                .foregroundColor(theme.textMuted)
                .frame(width: 60, alignment: .trailing)
            }
          }
        }
      }
    }
  }

  private var historyCard: some View {
    card {
      VStack(alignment: .leading, spacing: 10) {
        sectionTitle("Past sessions")
        if store.history.isEmpty {
          Text("Your finished sessions will show up here.")
            .font(.custom("Figtree", size: 12))
            .foregroundColor(theme.textMuted)
        }
        ForEach(store.history.prefix(15)) { session in
          let end = session.endedAt ?? session.startedAt
          HStack(spacing: 12) {
            Text(Self.dayFormatter.string(from: session.startedAt))
              .font(.custom("Figtree", size: 12))
              .foregroundColor(theme.textSecondary)
              .frame(width: 130, alignment: .leading)
            Text(Self.duration(session.elapsed(at: end)))
              .font(.custom("Figtree", size: 12).monospacedDigit())
              .foregroundColor(theme.textPrimary)
              .frame(width: 60, alignment: .leading)
            if let score = session.focusScore(at: end) {
              Text("\(Int((score * 100).rounded()))% focused")
                .font(.custom("Figtree", size: 12))
                .foregroundColor(theme.textSecondary)
            }
            Text("\(session.completedTitles.count)/\(session.goalTitles.count) tasks")
              .font(.custom("Figtree", size: 12))
              .foregroundColor(theme.textMuted)
            Spacer()
            Button("View") { store.summarySessionID = session.id }
              .buttonStyle(.plain)
              .foregroundColor(theme.accent)
            Button { store.deleteSession(session.id) } label: { Image(systemName: "trash") }
              .buttonStyle(.plain)
              .foregroundColor(theme.textMuted)
          }
        }
      }
    }
  }

  // MARK: - Shared pieces

  private func timelineList(_ entries: [FlowSessionTimeline.Entry]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(entries) { entry in
        HStack(alignment: .top, spacing: 10) {
          RoundedRectangle(cornerRadius: 2)
            .fill(Self.kindColor(entry.kind))
            .frame(width: 4, height: 18)
          Text(
            "\(FlowSessionTimeline.clock(entry.startedAt))–\(FlowSessionTimeline.clock(entry.endedAt))"
          )
          .font(.custom("Figtree", size: 12).monospacedDigit())
          .foregroundColor(theme.textMuted)
          .frame(width: 96, alignment: .leading)
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
              .font(.custom("Figtree", size: 13))
              .foregroundColor(theme.textPrimary)
            if let done = entry.completedTasks, !done.isEmpty {
              Text("Finished: \(done.joined(separator: ", "))")
                .font(.custom("Figtree", size: 11))
                .foregroundColor(Color(hex: "3FA66B"))
            }
          }
          Spacer()
          if let category = entry.category {
            Text(category)
              .font(.custom("Figtree", size: 11))
              .foregroundColor(theme.chipText)
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .background(Capsule().fill(theme.chipFill))
          }
        }
      }
    }
  }

  private func taskEntryField(placeholder: String, onSubmit: @escaping (String) -> Void)
    -> some View
  {
    HStack(spacing: 8) {
      TextField(placeholder, text: $newTask)
        .textFieldStyle(.roundedBorder)
        .font(.custom("Figtree", size: 13))
        .onSubmit {
          onSubmit(newTask)
          newTask = ""
        }
      Button("Add") {
        onSubmit(newTask)
        newTask = ""
      }
      .disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
    }
  }

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.cardFill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(
          theme.cardBorder, lineWidth: 1)
      )
  }

  private func sectionTitle(_ text: LocalizedStringKey) -> some View {
    Text(text)
      .font(.custom("Figtree", size: 16).weight(.semibold))
      .foregroundColor(theme.textPrimary)
  }

  private func label(_ text: LocalizedStringKey) -> some View {
    Text(text)
      .font(.custom("Figtree", size: 11).weight(.semibold))
      .foregroundColor(theme.textMuted)
      .textCase(.uppercase)
  }

  private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(.custom("Figtree", size: 17).weight(.semibold).monospacedDigit())
        .foregroundColor(theme.textPrimary)
      Text(title)
        .font(.custom("Figtree", size: 11))
        .foregroundColor(theme.textMuted)
    }
  }

  private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.custom("Figtree", size: 12).weight(.medium))
        .foregroundColor(selected ? theme.accentText : theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(selected ? theme.accent : theme.chipFill))
        .overlay(Capsule().stroke(selected ? Color.clear : theme.chipBorder, lineWidth: 1))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  private func primaryButton(
    _ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .font(.custom("Figtree", size: 13).weight(.semibold))
        .padding(.horizontal, 6)
    }
    .buttonStyle(.borderedProminent)
    .tint(theme.accent)
  }

  private func refreshWeek() async {
    weekCategories = await store.categoryWeek().filter { $0.minutes > 0 }
      .sorted { $0.minutes > $1.minutes }
  }

  // MARK: - Formatting

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE d MMM, HH:mm"
    return formatter
  }()

  static func clock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, secs)
      : String(format: "%d:%02d", minutes, secs)
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int((seconds / 60).rounded()))
    return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
  }

  static func kindColor(_ kind: FlowSessionTimeline.Kind) -> Color {
    switch kind {
    case .focused: return Color(hex: "3FA66B")
    case .distracted: return Color(hex: "E8743B")
    case .`break`: return Color(hex: "5B8DEF")
    }
  }

  static func styleTitle(_ style: FlowAlertStyle) -> String {
    switch style {
    case .quiet: return String(localized: "Quiet")
    case .friendly: return String(localized: "Friendly")
    case .feisty: return String(localized: "Feisty")
    }
  }

  static func styleDescription(_ style: FlowAlertStyle) -> String {
    switch style {
    case .quiet:
      return String(localized: "No pop-ups. Drifts are still logged for your summary.")
    case .friendly:
      return String(localized: "The creature pops in with a gentle nudge.")
    case .feisty:
      return String(localized: "The creature gets louder if you keep drifting.")
    }
  }
}
