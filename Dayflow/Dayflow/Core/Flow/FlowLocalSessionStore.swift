//
//  FlowLocalSessionStore.swift
//  Dayflow
//
//  Local, offline replacement for the hosted Flow web app and its backend.
//  It owns Flow's data (task list, the running session, past sessions) on
//  disk and stands in for the web page on the native side of the bridge:
//  FlowSessionMirror sends it the same events it used to send the page
//  (overlay replies, distraction flips, tasks the agent saw finished, menu bar
//  session controls), and it answers by pushing FlowNativeSnapshots into the
//  mirror, just as the page did with its "state" command.
//
//  Data lives in ~/Library/Application Support/Dayflow/flow-local.json.
//

import Combine
import Foundation

struct FlowLocalTask: Codable, Identifiable, Equatable {
  var id: String
  var title: String
  var createdAt: Date
  var completedAt: Date?
  /// True when the agent saw it finished on screen, false when checked by hand.
  var completedByFlow: Bool = false

  var isDone: Bool { completedAt != nil }
}

struct FlowLocalInterval: Codable, Equatable {
  var start: Date
  var end: Date?

  func seconds(until now: Date) -> TimeInterval {
    max(0, (end ?? now).timeIntervalSince(start))
  }
}

struct FlowLocalSession: Codable, Identifiable, Equatable {
  var id: String
  var startedAt: Date
  var endedAt: Date?
  /// nil for an "always on" session.
  var plannedMinutes: Int?
  var alertStyle: FlowAlertStyle
  var goalIDs: [String]
  var goalTitles: [String]
  var completedTitles: [String] = []
  var distractions: [FlowLocalInterval] = []
  var breaks: [FlowLocalInterval] = []
  var endedNaturally = false
  var timeline: [FlowSessionTimeline.Entry] = []

  func elapsed(at now: Date) -> TimeInterval {
    max(0, (endedAt ?? now).timeIntervalSince(startedAt))
  }

  func breakSeconds(at now: Date) -> TimeInterval {
    breaks.reduce(0) { $0 + $1.seconds(until: endedAt ?? now) }
  }

  func distractedSeconds(at now: Date) -> TimeInterval {
    distractions.reduce(0) { $0 + $1.seconds(until: endedAt ?? now) }
  }

  func focusedSeconds(at now: Date) -> TimeInterval {
    max(0, elapsed(at: now) - breakSeconds(at: now) - distractedSeconds(at: now))
  }

  /// Share of non-break time spent on task, 0...1. nil before any time passed.
  func focusScore(at now: Date) -> Double? {
    let working = elapsed(at: now) - breakSeconds(at: now)
    guard working >= 30 else { return nil }
    return min(1, max(0, focusedSeconds(at: now) / working))
  }

  var openDistraction: Bool { distractions.last.map { $0.end == nil } ?? false }
  var openBreak: Bool { breaks.last.map { $0.end == nil } ?? false }
}

@MainActor
final class FlowLocalSessionStore: ObservableObject, FlowBridgeForwarding {
  static let shared = FlowLocalSessionStore()

  @Published private(set) var tasks: [FlowLocalTask] = []
  @Published private(set) var current: FlowLocalSession?
  /// Finished sessions, newest first.
  @Published private(set) var history: [FlowLocalSession] = []
  /// The session whose summary the Flow tab shows until dismissed.
  @Published var summarySessionID: String?
  /// Set when something outside the tab (menu bar, early-bird card) asked to
  /// start a session; the tab scrolls to / highlights setup.
  @Published var setupRequested = false

  @Published var defaultMinutes: Int = 50 { didSet { save() } }
  @Published var defaultAlwaysOn = false { didSet { save() } }
  @Published var defaultAlertStyle: FlowAlertStyle = .friendly { didSet { save() } }

  private var cancellables: Set<AnyCancellable> = []
  private var lastPhase: FlowPhase = .idle
  /// True while we push a snapshot ourselves, so the mirror observer only
  /// reacts to transitions the mirror makes on its own (timers).
  private var applying = false
  private var loading = false

  private var mirror: FlowSessionMirror { .shared }

  private init() {
    load()
  }

  /// Hooks the store up to the mirror. Called once at launch.
  func start() {
    guard cancellables.isEmpty else { return }
    reconcile(with: mirror.snapshot)
    lastPhase = mirror.snapshot.phase
    mirror.$snapshot
      .dropFirst()
      .sink { [weak self] snapshot in self?.mirrorChanged(snapshot) }
      .store(in: &cancellables)
  }

  // MARK: - Queries

  var phase: FlowPhase { mirror.snapshot.phase }
  var isSessionOn: Bool { phase == .active || phase == .onBreak }
  var openTasks: [FlowLocalTask] { tasks.filter { !$0.isDone } }
  var doneTasks: [FlowLocalTask] {
    tasks.filter(\.isDone).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
  }

  var summarySession: FlowLocalSession? {
    guard let summarySessionID else { return nil }
    return history.first { $0.id == summarySessionID }
  }

  func isGoal(_ task: FlowLocalTask) -> Bool {
    current?.goalIDs.contains(task.id) ?? false
  }

  // MARK: - Session control

  /// Starts a session. `minutes == nil` means always on.
  func startSession(goalIDs: [String], minutes: Int?, alertStyle: FlowAlertStyle) {
    guard !isSessionOn else { return }
    let now = Date()
    let goals = tasks.filter { goalIDs.contains($0.id) && !$0.isDone }
    current = FlowLocalSession(
      id: UUID().uuidString,
      startedAt: now,
      plannedMinutes: minutes,
      alertStyle: alertStyle,
      goalIDs: goals.map(\.id),
      goalTitles: goals.map(\.title))
    summarySessionID = nil
    setupRequested = false

    var snapshot = FlowNativeSnapshot()
    snapshot.phase = .active
    snapshot.alertStyle = alertStyle
    snapshot.alwaysOn = minutes == nil
    snapshot.sessionStartedAt = Int(now.timeIntervalSince1970)
    if let minutes { snapshot.sessionEndsAt = Int(now.timeIntervalSince1970) + minutes * 60 }
    snapshot.goals = goals.map(\.title)
    snapshot.goalTasks = goals.map { FlowGoalTask(id: $0.id, title: $0.title) }
    push(snapshot)
    save()
  }

  func takeBreak(minutes: Int) {
    guard phase == .active, current != nil else { return }
    let now = Date()
    closeDistraction(at: now)
    current?.breaks.append(FlowLocalInterval(start: now))
    var snapshot = mirror.snapshot
    snapshot.phase = .onBreak
    snapshot.breakEndsAt = Int(now.timeIntervalSince1970) + minutes * 60
    // Breaks don't eat into a timed session: push the end back by the break.
    if let endsAt = snapshot.sessionEndsAt { snapshot.sessionEndsAt = endsAt + minutes * 60 }
    push(snapshot)
    save()
  }

  func resumeFromBreak() {
    guard phase == .onBreak else { return }
    let now = Date()
    var snapshot = mirror.snapshot
    // Coming back early gives back the unused part of the break.
    if let breakEnds = snapshot.breakEndsAt, let endsAt = snapshot.sessionEndsAt {
      let unused = max(0, breakEnds - Int(now.timeIntervalSince1970))
      snapshot.sessionEndsAt = endsAt - unused
    }
    snapshot.phase = .active
    snapshot.breakEndsAt = nil
    snapshot.goalTasks = openGoalTasks()
    snapshot.goals = snapshot.goalTasks?.map(\.title)
    closeBreak(at: now)
    push(snapshot)
    save()
  }

  func endSession() {
    guard isSessionOn else { return }
    push(.idle)
    finalizeSoon(naturally: false)
  }

  func dismissSummary() {
    summarySessionID = nil
  }

  func deleteSession(_ id: String) {
    history.removeAll { $0.id == id }
    if summarySessionID == id { summarySessionID = nil }
    save()
  }

  // MARK: - Tasks

  func addTask(_ title: String, addToSession: Bool = true) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let task = FlowLocalTask(id: UUID().uuidString, title: String(trimmed.prefix(200)), createdAt: Date())
    tasks.append(task)
    if addToSession, current != nil {
      current?.goalIDs.append(task.id)
      current?.goalTitles.append(task.title)
      pushGoalsIfActive()
    }
    save()
  }

  func toggleDone(_ id: String) {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
    if tasks[index].isDone {
      tasks[index].completedAt = nil
      tasks[index].completedByFlow = false
      current?.completedTitles.removeAll { $0 == tasks[index].title }
      pushGoalsIfActive()
      save()
    } else {
      markCompleted([id], byFlow: false)
    }
  }

  func toggleGoal(_ id: String) {
    guard current != nil, let task = tasks.first(where: { $0.id == id }) else { return }
    if current!.goalIDs.contains(id) {
      current?.goalIDs.removeAll { $0 == id }
      current?.goalTitles.removeAll { $0 == task.title }
    } else {
      current?.goalIDs.append(id)
      current?.goalTitles.append(task.title)
    }
    pushGoalsIfActive()
    save()
  }

  func deleteTask(_ id: String) {
    tasks.removeAll { $0.id == id }
    if current?.goalIDs.contains(id) == true {
      current?.goalIDs.removeAll { $0 == id }
      pushGoalsIfActive()
    }
    save()
  }

  func clearCompleted() {
    tasks.removeAll(where: \.isDone)
    save()
  }

  private func markCompleted(_ ids: [String], byFlow: Bool) {
    let now = Date()
    var changed = false
    for id in ids {
      guard let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].isDone else {
        continue
      }
      tasks[index].completedAt = now
      tasks[index].completedByFlow = byFlow
      if current != nil, !(current!.completedTitles.contains(tasks[index].title)) {
        current?.completedTitles.append(tasks[index].title)
      }
      changed = true
    }
    guard changed else { return }
    pushGoalsIfActive()
    save()
  }

  private func openGoalTasks() -> [FlowGoalTask] {
    guard let current else { return [] }
    return current.goalIDs.compactMap { id in
      tasks.first { $0.id == id && !$0.isDone }.map { FlowGoalTask(id: $0.id, title: $0.title) }
    }
  }

  /// Tells the mirror (and through it the agent) about the session's open
  /// goals. During a break the mirror would replay the break on any push, so
  /// goals catch up on resume instead.
  private func pushGoalsIfActive() {
    guard phase == .active, current != nil else { return }
    var snapshot = mirror.snapshot
    let goals = openGoalTasks()
    snapshot.goalTasks = goals
    snapshot.goals = goals.map(\.title)
    guard snapshot != mirror.snapshot else { return }
    push(snapshot)
  }

  // MARK: - FlowBridgeForwarding (events the web page used to receive)

  func sendEvent(_ event: String, payload: [String: Any]) {
    switch event {
    case "sessionControl":
      switch payload["action"] as? String {
      case "start":
        if !isSessionOn { setupRequested = true }
      case "break":
        takeBreak(minutes: payload["minutes"] as? Int ?? 5)
      case "resume":
        resumeFromBreak()
      case "end":
        endSession()
      default:
        break
      }
    case "distractionSimulated":
      guard phase == .active, current != nil, !(current!.openDistraction) else { return }
      current?.distractions.append(FlowLocalInterval(start: Date()))
      save()
    case "distractionEnded":
      closeDistraction(at: Date())
      save()
    case "overlayAction":
      if payload["action"] as? String == "backToWork" {
        closeDistraction(at: Date())
        save()
      }
    case "tasksCompleted":
      markCompleted(payload["ids"] as? [String] ?? [], byFlow: true)
    default:
      // onboardingAlertReply, supportUnread, …: nothing local to do.
      break
    }
  }

  // MARK: - Mirror sync

  private func push(_ snapshot: FlowNativeSnapshot) {
    applying = true
    mirror.apply(snapshot)
    lastPhase = snapshot.phase
    applying = false
  }

  /// Transitions the mirror makes on its own: a timed session or break
  /// running out.
  private func mirrorChanged(_ snapshot: FlowNativeSnapshot) {
    let previous = lastPhase
    lastPhase = snapshot.phase
    guard !applying, previous != snapshot.phase else { return }
    switch (previous, snapshot.phase) {
    case (.onBreak, .active):
      closeBreak(at: Date())
      // The mirror's break timer doesn't wake the agent; the page used to.
      FlowDistractionAgent.shared.resume()
      DispatchQueue.main.async { [weak self] in self?.pushGoalsIfActive() }
      save()
    case (.active, .ended), (.onBreak, .ended), (.active, .idle), (.onBreak, .idle):
      finalizeSoon(naturally: snapshot.phase == .ended)
    default:
      break
    }
  }

  /// Launch: line the stored session up with whatever the mirror restored.
  private func reconcile(with snapshot: FlowNativeSnapshot) {
    switch snapshot.phase {
    case .active, .onBreak:
      if current == nil {
        let started = snapshot.sessionStartedAt ?? Int(Date().timeIntervalSince1970)
        // A session we have no record of (e.g. started by an older build).
        let goals = snapshot.goalTasks ?? []
        current = FlowLocalSession(
          id: UUID().uuidString,
          startedAt: Date(timeIntervalSince1970: TimeInterval(started)),
          plannedMinutes: snapshot.sessionEndsAt.map { ($0 - started) / 60 },
          alertStyle: snapshot.alertStyle,
          goalIDs: goals.map(\.id),
          goalTitles: goals.map(\.title))
        save()
      }
    case .idle, .ended:
      if current != nil { finalize(naturally: snapshot.phase == .ended) }
    }
  }

  /// The mirror publishes before it finishes the timeline; let it settle.
  private func finalizeSoon(naturally: Bool) {
    DispatchQueue.main.async { [weak self] in self?.finalize(naturally: naturally) }
  }

  private func finalize(naturally: Bool) {
    guard var session = current else { return }
    let now = Date()
    var end = now
    if naturally, let planned = session.plannedMinutes {
      let plannedEnd =
        session.startedAt.addingTimeInterval(
          TimeInterval(planned * 60) + session.breakSeconds(at: now))
      end = min(now, plannedEnd)
    }
    session.endedAt = end
    session.endedNaturally = naturally
    for index in session.distractions.indices where session.distractions[index].end == nil {
      session.distractions[index].end = end
    }
    for index in session.breaks.indices where session.breaks[index].end == nil {
      session.breaks[index].end = end
    }
    session.timeline = FlowSessionTimeline.shared.entries
    history.insert(session, at: 0)
    if history.count > 500 { history.removeLast(history.count - 500) }
    current = nil
    summarySessionID = session.id
    save()
  }

  private func closeDistraction(at date: Date) {
    guard let current, current.openDistraction else { return }
    self.current?.distractions[current.distractions.count - 1].end = date
  }

  private func closeBreak(at date: Date) {
    guard let current, current.openBreak else { return }
    self.current?.breaks[current.breaks.count - 1].end = date
  }

  // MARK: - Week by category (same numbers the web page's radar used)

  struct CategoryMinutes: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let colorHex: String
    let minutes: Double
  }

  func categoryWeek() async -> [CategoryMinutes] {
    let categories = CategoryStore.shared.categories
      .filter { !$0.isIdle && !$0.isSystem }
      .sorted { $0.order < $1.order }
    let minutes = await Task.detached(priority: .userInitiated) { () -> [String: Double] in
      let now = Date()
      let start = now.addingTimeInterval(-7 * 24 * 60 * 60)
      var totals: [String: Double] = [:]
      for card in StorageManager.shared.fetchTimelineCardsByTimeRange(from: start, to: now) {
        guard let from = WeeklyDashboardBuilder.parseCardMinute(card.startTimestamp),
          let to = WeeklyDashboardBuilder.parseCardMinute(card.endTimestamp)
        else { continue }
        let range = WeeklyDashboardBuilder.normalizedMinuteRange(start: from, end: to)
        let key = card.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        totals[key, default: 0] += max(0, range.end - range.start)
      }
      return totals
    }.value
    return categories.map { category in
      let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
      return CategoryMinutes(
        name: name, colorHex: category.colorHex, minutes: (minutes[name.lowercased()] ?? 0).rounded())
    }
  }

  // MARK: - Persistence

  private struct StoredData: Codable {
    var tasks: [FlowLocalTask]
    var current: FlowLocalSession?
    var history: [FlowLocalSession]
    var defaultMinutes: Int?
    var defaultAlwaysOn: Bool?
    var defaultAlertStyle: FlowAlertStyle?
  }

  private static var fileURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("Dayflow", isDirectory: true)
      .appendingPathComponent("flow-local.json")
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  private func load() {
    loading = true
    defer { loading = false }
    guard let data = try? Data(contentsOf: Self.fileURL),
      let stored = try? Self.decoder.decode(StoredData.self, from: data)
    else { return }
    tasks = stored.tasks
    current = stored.current
    history = stored.history
    defaultMinutes = stored.defaultMinutes ?? 50
    defaultAlwaysOn = stored.defaultAlwaysOn ?? false
    defaultAlertStyle = stored.defaultAlertStyle ?? .friendly
  }

  private func save() {
    guard !loading else { return }
    let stored = StoredData(
      tasks: tasks, current: current, history: history,
      defaultMinutes: defaultMinutes, defaultAlwaysOn: defaultAlwaysOn,
      defaultAlertStyle: defaultAlertStyle)
    guard let data = try? Self.encoder.encode(stored) else { return }
    let url = Self.fileURL
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    } catch {
      print("[FlowLocal] Couldn't save: \(error)")
    }
  }
}
