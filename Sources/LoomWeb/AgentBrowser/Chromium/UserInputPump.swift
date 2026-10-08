import CoreGraphics
import Foundation
import LoomChromium

// The person's input in the side panel, on its way to the agent's page
// (panel design §2–§3). The pure parts are LoomChromium's — the gate, the
// mappings, the coalescer — and they are driven exactly as the golden
// sequences replay them (GoldenSequenceTests' Replayer):
//
//     pressTarget → gate.admit → map → gate.didForward → coalescer.submit
//
// then sent through the current tab's DevTools session: `write` as one
// post(batch:), in order, never awaited per key; the coalescer's `tracked`
// move or wheel as one call whose reply frees the next one.
//
// Two things wait for the page, and the events that come meanwhile queue
// behind them (the barrier) and go in order once they are done:
// - a plain left press first asks what is under it (SelectMenuBridge: a
//   one-line <select> gets a Mac menu, Chromium's own popup showing in no
//   frame), 50 ms at most;
// - a paste first offers the page its `paste` event (PanelClipboard).
//
// The agent wins: ChromiumAgentBrowser.run calls `agentWillAct` before a
// command enters the core — what the person holds comes up, their pending
// moves go, the gate shuts — and `agentDidFinish` once it is done.
// A tab switch, a relaunch or a crash gives the pump another page
// (`attach`): nothing of the person's is held there.

/// Where the pump's commands go: the tab's DevTools session
/// (`ChromiumPanelWire`), or a test's recorder.
@MainActor
protocol PanelInputWire: AnyObject {
    /// In order, in one write; nothing awaited.
    func write(_ commands: [PanelCDPCommand])
    /// The coalescer's one request in flight: `replied` runs on the main
    /// actor once its reply, or its failure, is in.
    func track(_ command: PanelCDPCommand, replied: @escaping @MainActor @Sendable () -> Void)
    /// Returns once what was written so far is answered — the keys reached
    /// the page — or after `limit`.
    func drain(within limit: Duration) async
}

/// What the pump asks of the panel around it (ChromiumAgentSurface; a
/// test's fake).
@MainActor
protocol UserInputPumpHost: AnyObject {
    /// One op of the panel script on `tab`'s page (AgentPanelScript); nil
    /// when refused (the agent acts, a dialog blocks), failed or late.
    func panelQuery(_ op: String, _ arg: PanelJSON, on tab: BrowserTabsModel.TabID,
                    timeout: Duration) async -> PanelJSON?
    /// The person clicked or typed in `tab`'s page: once per gap between the
    /// agent's commands.
    func noteUserActed(on tab: BrowserTabsModel.TabID)
    /// Why the person's input did not reach the page, for a few seconds.
    func showInputNotice(_ text: String)
    /// The panel's own chrome: the address bar, reload, back, forward.
    func performPanelAction(_ action: PanelAction)
}

/// The page view showing the pump's page: what only a view can do.
@MainActor
protocol UserInputPumpViewer: AnyObject {
    /// The page's cursor under the pointer, sampled.
    func pumpCursorChanged(_ kind: CursorKind)
    /// The page's composition was cancelled (the agent took over, another
    /// page came): the input method's marked text goes too.
    func pumpCompositionEnded()
    /// The Mac menu of a <select>: `completion` gets the chosen option's
    /// index, or nil — exactly once.
    func pumpChoose(from menu: SelectMenuModel, completion: @escaping @MainActor (Int?) -> Void)
}

/// A tab's session as the pump's wire.
@MainActor
final class ChromiumPanelWire: PanelInputWire {

    /// A write's replies are dropped past this: an input that opened a
    /// dialog is only answered once the dialog is.
    static let writeLimit: Duration = .seconds(10)
    /// The tracked move or wheel: past this (or a dialog), the next one goes.
    static let trackedLimit: Duration = .seconds(5)

    let source: ChromiumScreencastSource
    /// The replies of the last write: what `drain` waits for.
    private var lastWrite: [CDPReply] = []

    init(source: ChromiumScreencastSource) {
        self.source = source
    }

    func write(_ commands: [PanelCDPCommand]) {
        guard !commands.isEmpty else { return }
        lastWrite = source.connection.post(batch: PanelCDPCommand.cdpBatch(commands), session: source.session,
                                           options: CDPCallOptions(deadline: ContinuousClock.now + Self.writeLimit))
    }

    func track(_ command: PanelCDPCommand, replied: @escaping @MainActor @Sendable () -> Void) {
        let wire = command.cdpCommand
        let options = CDPCallOptions(deadline: ContinuousClock.now + Self.trackedLimit,
                                     interruptible: [.dialogOpened, .crashed, .detached])
        let reply = source.connection.post(wire.0, wire.1, session: source.session, options: options)
        Task { @MainActor in
            _ = try? await reply.value()
            replied()
        }
    }

    func drain(within limit: Duration) async {
        let replies = lastWrite
        guard !replies.isEmpty else { return }
        let end = ContinuousClock.now + limit
        // Input events are answered in order: the last write's replies
        // stand for every write before it.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for reply in replies {
                    _ = try? await reply.value()
                }
            }
            group.addTask {
                try? await Task.sleep(until: end, clock: .continuous)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }
}

@MainActor
final class UserInputPump {

    /// A cursor sample waits this long after the last forwarded move.
    static let cursorDelay: Duration = .milliseconds(60)
    static let cursorBudget: Duration = .milliseconds(150)
    static let caretBudget: Duration = .milliseconds(150)

    weak var host: (any UserInputPumpHost)?
    weak var viewer: (any UserInputPumpViewer)?
    let pasteboard: any PanelPasteboard

    private(set) var gate = UserInputGate()
    private(set) var pointer = UserPointerMapping()
    private(set) var keys = UserKeyMapping()
    private var coalescer = InputCoalescer()
    private(set) var wire: (any PanelInputWire)?
    /// The tab whose page the input goes to.
    private(set) var tab: BrowserTabsModel.TabID?
    /// Bumped by every `attach`: what an earlier page's replies and flows
    /// come back to is dropped.
    private(set) var generation = 0
    /// Agent commands entered and not yet returned: they queue in the core,
    /// and the gate stays shut until the last one is done.
    private var agentCommands = 0
    /// The core still runs an agent command (its published activity) — one
    /// whose caller stopped waiting too (the core's backstop answered): the
    /// page stays the agent's until it is really done.
    private var coreRunning = false
    /// Bumped by every takeover: a flow that began before the agent acted
    /// (a press's probe, a paste, a copy) sends nothing of it after.
    private(set) var takeovers = 0
    /// The tabs the agent was told about since its last command.
    private var notedTabs: Set<BrowserTabsModel.TabID> = []

    // The barrier: events that wait for a press's probe or a paste.
    private var barrier = false
    private var waiting: [@MainActor () -> Void] = []
    // What runs beyond one event (probe, paste, copy), until done.
    private var flows: [Int: Task<Void, Never>] = [:]
    private var nextFlow = 0

    /// A plain left press went without its probe's answer: its release asks
    /// again, in case it opened a <select>'s popup no frame shows.
    var slippedPress: CGPoint?

    // The cursor's sample: trailing, one in flight.
    private var cursorPoint: CGPoint?
    private var cursorTimer: Task<Void, Never>?
    private var cursorInFlight = false

    init(pasteboard: any PanelPasteboard) {
        self.pasteboard = pasteboard
    }

    /// On the Mac's own pasteboard.
    convenience init() {
        self.init(pasteboard: SystemPanelPasteboard())
    }

    // MARK: - The page and the agent

    /// Another page under the panel — a tab switch, a relaunch, a crash —
    /// or none (`wire` nil): nothing of the person's is held there.
    func attach(_ newWire: (any PanelInputWire)?, tab newTab: BrowserTabsModel.TabID?) {
        let wasComposing = keys.composing
        generation += 1
        wire = newWire
        tab = newTab
        gate.reset()
        gate.live = newWire != nil
        coalescer.reset()
        pointer.agentTookOver()
        keys.agentTookOver()
        barrier = false
        waiting = []
        slippedPress = nil
        cancelCursorSample()
        if wasComposing {
            viewer?.pumpCompositionEnded()
        }
    }

    /// A JavaScript dialog blocks the page (a file chooser does not).
    func setPageBlocked(_ blocked: Bool) {
        gate.pageBlocked = blocked
    }

    /// The page view is first responder in the key window: moves may go.
    func setFirstResponder(_ armed: Bool) {
        gate.isFirstResponder = armed
    }

    /// Before an agent command enters the core: the buttons the person
    /// holds come up at the last point, their keys too, a composition is
    /// cancelled, their waiting moves go — then the gate stays shut.
    func agentWillAct() {
        agentCommands += 1
        notedTabs.removeAll()
        takeOver()
    }

    /// The agent command returned or threw; the person's turn once none is
    /// left, and the core runs none either.
    func agentDidFinish() {
        agentCommands = max(0, agentCommands - 1)
        reopenIfDone()
    }

    /// The core's activity: an agent command runs there. The gate stays shut
    /// while it does, even past its caller's return (`agentDidFinish` after
    /// the core's backstop answered for a job still running).
    func setAgentRunningInCore(_ running: Bool) {
        guard running != coreRunning else { return }
        coreRunning = running
        if running {
            if !gate.agentRunning {
                takeOver()
            }
        } else {
            reopenIfDone()
        }
    }

    private func reopenIfDone() {
        if agentCommands == 0, !coreRunning {
            gate.agentDidFinish()
        }
    }

    /// The agent takes the page: what the person holds comes up, their
    /// composition is cancelled, what waits of theirs (pending moves, events
    /// behind a barrier, a slipped press's second look) goes — it came
    /// before the agent acted.
    private func takeOver() {
        let releases = gate.agentWillAct(lastPoint: pointer.lastPoint)
        pointer.agentTookOver()
        keys.agentTookOver()
        coalescer.discardPending()
        takeovers += 1
        waiting = []
        slippedPress = nil
        cancelCursorSample()
        if !releases.isEmpty {
            wire?.write(releases)
        }
        // The view checks it has marked text: the mapping may not know of
        // a key the gate dropped while the input method composed it.
        viewer?.pumpCompositionEnded()
    }

    /// Whether a keyDown would reach the page now: when not, the view does
    /// not even hand it to the input method.
    var acceptsKeys: Bool {
        gate.isOpen
    }

    // MARK: - Mouse

    /// Any button. The page view became first responder just before (the
    /// only place it takes the keyboard).
    func mouseDown(_ event: MacMouseEvent, geometry: ScreencastGeometry) {
        gate.isFirstResponder = true
        enqueue { [weak self] in
            self?.press(event, geometry: geometry)
        }
    }

    func mouseDragged(_ event: MacMouseEvent, geometry: ScreencastGeometry) {
        enqueue { [weak self] in
            guard let self, let button = event.button, self.admit(.mouseDrag(button)) else { return }
            self.forward(self.pointer.mouseDragged(event, geometry: geometry))
        }
    }

    func mouseUp(_ event: MacMouseEvent, geometry: ScreencastGeometry) {
        enqueue { [weak self] in
            guard let self, let button = event.button, self.admit(.mouseUp(button)) else { return }
            self.forward(self.pointer.mouseUp(event, geometry: geometry))
            if button == .left, let point = self.slippedPress {
                self.slippedPress = nil
                self.recheckSelect(at: point)
            }
        }
    }

    /// A bare move: only once the view is armed (the gate says).
    func mouseMoved(_ event: MacMouseEvent, geometry: ScreencastGeometry) {
        enqueue { [weak self] in
            guard let self, self.admit(.mouseMove) else { return }
            self.forward(self.pointer.mouseMoved(event, geometry: geometry))
        }
    }

    /// The pointer left the view: the page's :hover clears.
    func mouseExited() {
        enqueue { [weak self] in
            guard let self, self.admit(.mouseExited) else { return }
            self.forward(self.pointer.mouseExited())
        }
    }

    /// Momentum events too: their decaying deltas are the inertia.
    func scrollWheel(_ event: MacScrollEvent, geometry: ScreencastGeometry) {
        enqueue { [weak self] in
            guard let self, self.admit(.wheel) else { return }
            self.forward(self.pointer.wheel(event, geometry: geometry))
        }
    }

    private func press(_ event: MacMouseEvent, geometry: ScreencastGeometry) {
        switch pointer.pressTarget(event, geometry: geometry) {
        case .outside:
            return
        case .history(let direction):
            guard admit(.panelAction) else { return }
            switch direction {
            case .back: host?.performPanelAction(.back)
            case .forward: host?.performPanelAction(.forward)
            }
        case .page(let point):
            guard let button = event.button else { return }
            if SelectMenuBridge.probes(event), gate.isOpen, host != nil, tab != nil {
                probeSelect(event, geometry: geometry, at: point)
                return
            }
            forwardPress(event, geometry: geometry, button: button)
        }
    }

    /// The press goes to the page (the move first, if the page had the
    /// pointer elsewhere).
    func forwardPress(_ event: MacMouseEvent, geometry: ScreencastGeometry, button: MouseButtonName) {
        guard admit(.mouseDown(button)) else { return }
        noteActed()
        forward(pointer.mouseDown(event, geometry: geometry))
    }

    // MARK: - Keyboard

    /// A keyDown and what AppKit called back while interpreting it.
    func keyDown(_ press: MacKeyPress, actions: [KeyAction]) {
        enqueue { [weak self] in
            guard let self, self.admit(.keyDown(keyCode: press.keyCode)) else { return }
            let commands = UserInputPump.withoutPasteCommand(self.keys.keyDown(press, actions: actions))
            if !commands.isEmpty {
                self.noteActed()
            }
            self.forward(commands)
        }
    }

    /// A keyDown the view did not even interpret — the page is not the
    /// person's now (`acceptsKeys`): dropped at once, with the notice why.
    /// Never queued: behind a barrier it could outlive the agent's command
    /// and reach the page as a bare key, its text never interpreted.
    func refuseKeyDown(_ press: MacKeyPress) {
        guard !gate.isOpen else { return }
        _ = admit(.keyDown(keyCode: press.keyCode))
    }

    func keyUp(_ press: MacKeyPress) {
        enqueue { [weak self] in
            guard let self, self.admit(.keyUp(keyCode: press.keyCode)) else { return }
            self.forward(self.keys.keyUp(press))
        }
    }

    func flagsChanged(_ press: MacKeyPress) {
        enqueue { [weak self] in
            guard let self, self.admit(.flagsChanged(keyCode: press.keyCode)) else { return }
            self.forward(self.keys.flagsChanged(press))
        }
    }

    /// What AppKit inserts or marks outside a keyDown (the emoji picker,
    /// dictation, a candidate clicked in an input method's window).
    func text(_ actions: [KeyAction]) {
        enqueue { [weak self] in
            guard let self, self.admit(.text) else { return }
            let commands = self.keys.text(actions)
            if !commands.isEmpty {
                self.noteActed()
            }
            self.forward(commands)
        }
    }

    /// The page view resigned first responder: the marked text is committed,
    /// as the page itself would on a blur, and the pointer leaves.
    func resign() {
        gate.isFirstResponder = false
        enqueue { [weak self] in
            guard let self else { return }
            let committed = self.keys.commitComposition()
            if self.stillPersons() {
                self.forward(committed)
            }
            guard self.admit(.mouseExited) else { return }
            self.forward(self.pointer.mouseExited())
        }
    }

    /// The focused field's caret in CSS px of the main frame: where an input
    /// method's window goes (asked once per composition).
    func caretRect() async -> CGRect? {
        guard gate.isOpen, let host, let tab else { return nil }
        guard let answer = await host.panelQuery("caretRect", .null, on: tab, timeout: Self.caretBudget) else {
            return nil
        }
        return Self.rect(answer)
    }

    // MARK: - The panel's own chrome

    /// ⌘L, ⌘R, ⌘[, ⌘] and the mouse's side buttons. The address bar is
    /// Loom's and always takes the keyboard; the rest acts on the page.
    func panelAction(_ action: PanelAction) {
        switch action {
        case .focusAddress:
            host?.performPanelAction(action)
        case .reload, .back, .forward:
            guard admit(.panelAction) else { return }
            host?.performPanelAction(action)
        }
    }

    // MARK: - The flow

    /// Whether an agent command is in the core's queue now — read across
    /// threads (the core's control), so a takeover told to the main actor
    /// and not landed yet still shuts the gate.
    var agentBusy: (() -> Bool)?

    /// Whether a flow that resumes may still send the person's input: an
    /// agent command that entered the core meanwhile takes the page first,
    /// as `admit` does — a paste's text, an Escape or a commit never lands
    /// among the agent's own input.
    func stillPersons() -> Bool {
        if !gate.agentRunning, agentBusy?() == true {
            takeOver()
        }
        return gate.isOpen
    }

    /// The gate's verdict; a refused press, key or paste says why.
    func admit(_ event: GateEvent) -> Bool {
        if !gate.agentRunning, agentBusy?() == true {
            // The agent's command entered the core before its takeover
            // reached the main actor: the page is already the agent's.
            takeOver()
        }
        switch gate.admit(event) {
        case .forward:
            return true
        case .drop(let notice):
            if let notice {
                host?.showInputNotice(notice.text)
            }
            return false
        }
    }

    /// What the mapping made of an admitted event: recorded by the gate,
    /// then sent through the coalescer.
    func forward(_ commands: [PanelCDPCommand]) {
        guard !commands.isEmpty else { return }
        gate.didForward(commands)
        send(coalescer.submit(commands))
        let pointerMoved = commands.contains { command in
            command.method == PanelCDPCommand.dispatchMouseEvent && command.type != "mouseWheel"
        }
        if pointerMoved, let point = pointer.lastPoint {
            scheduleCursorSample(at: point)
        }
    }

    private func send(_ output: InputCoalescer.Output) {
        guard let wire else {
            coalescer.reset()
            return
        }
        if !output.write.isEmpty {
            wire.write(output.write)
        }
        if let tracked = output.tracked {
            track(tracked, on: wire)
        }
    }

    private func track(_ command: PanelCDPCommand, on wire: any PanelInputWire) {
        let expected = generation
        wire.track(command) { [weak self] in
            guard let self, self.generation == expected else { return }
            guard let next = self.coalescer.didReceiveReply() else { return }
            if let current = self.wire {
                self.track(next, on: current)
            } else {
                self.coalescer.reset()
            }
        }
    }

    /// The agent hears of it once per gap between its commands, per tab.
    func noteActed() {
        guard let tab, !notedTabs.contains(tab) else { return }
        notedTabs.insert(tab)
        host?.noteUserActed(on: tab)
    }

    /// Now, or after what waits for the page.
    func enqueue(_ handle: @escaping @MainActor () -> Void) {
        if barrier {
            waiting.append(handle)
        } else {
            handle()
        }
    }

    /// Events wait from now on, until `lowerBarrier`. No cursor sample
    /// meanwhile: its `hitInfo` would move the panel script's last hit, the
    /// one a <select>'s `chooseUserSelect` reads.
    func raiseBarrier() {
        barrier = true
        cursorTimer?.cancel()
        cursorTimer = nil
    }

    /// What waited goes, in order — unless one of them raises the barrier
    /// again. Nothing for an earlier page's flow (`attach` cleared it).
    func lowerBarrier(generation expected: Int) {
        guard expected == generation else { return }
        barrier = false
        while !barrier, !waiting.isEmpty {
            let next = waiting.removeFirst()
            next()
        }
    }

    /// Work beyond one event: a probe, a paste, a copy.
    func startFlow(_ body: @escaping @MainActor @Sendable () async -> Void) {
        nextFlow += 1
        let id = nextFlow
        flows[id] = Task { @MainActor [weak self] in
            await body()
            self?.flows[id] = nil
        }
    }

    /// Returns once every flow started so far, and those they started, are
    /// done (tests; nothing in the app waits on it).
    func waitForFlows() async {
        while let entry = flows.first {
            await entry.value.value
            flows[entry.key] = nil
        }
    }

    // MARK: - The cursor

    private func scheduleCursorSample(at point: CGPoint) {
        guard viewer != nil else { return }
        cursorPoint = point
        cursorTimer?.cancel()
        cursorTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: UserInputPump.cursorDelay)
            guard !Task.isCancelled, let self else { return }
            self.cursorTimer = nil
            self.sampleCursor()
        }
    }

    /// One `hitInfo` at a time — the slot is freed by its answer only, even
    /// across a takeover or another page; none while the page is not the
    /// person's, nor while a flow waits for the page.
    private func sampleCursor() {
        guard !cursorInFlight, !barrier, gate.isOpen, let point = cursorPoint, host != nil, let tab else { return }
        cursorInFlight = true
        let expected = generation
        Task { @MainActor [weak self] in
            guard let host = self?.host else {
                self?.cursorInFlight = false
                return
            }
            let answer = await host.panelQuery("hitInfo", UserInputPump.hitArguments(point, select: false), on: tab,
                                               timeout: UserInputPump.cursorBudget)
            guard let self else { return }
            self.cursorInFlight = false
            guard self.generation == expected else { return }
            if let answer, let kind = UserInputPump.cursorKind(hitInfo: answer) {
                self.viewer?.pumpCursorChanged(kind)
            }
            // The pointer moved on meanwhile: its place is sampled too.
            if let latest = self.cursorPoint, latest != point, self.cursorTimer == nil {
                self.sampleCursor()
            }
        }
    }

    /// The request in flight, if any, keeps its slot until it answers.
    private func cancelCursorSample() {
        cursorTimer?.cancel()
        cursorTimer = nil
        cursorPoint = nil
    }

    // MARK: - Pure parts

    /// A key binding of the person's own (DefaultKeyBinding.dict) may name
    /// `paste:`: the key goes without it. Chromium's paste command reads the
    /// clipboard every context of the process shares (step-9 probe
    /// "Clipboard scope"); the person's paste is the bridge's (⌘V, Edit ▸
    /// Paste).
    nonisolated static func withoutPasteCommand(_ commands: [PanelCDPCommand]) -> [PanelCDPCommand] {
        commands.map { command in
            guard let names = command.params["commands"]?.arrayValue, names.contains(.string("paste")) else {
                return command
            }
            var stripped = command
            let kept = names.filter { $0 != .string("paste") }
            stripped.params["commands"] = kept.isEmpty ? nil : PanelJSON.array(kept)
            return stripped
        }
    }

    /// `hitInfo`'s argument: a point in CSS px; `select: false` leaves the
    /// <select> description out (the cursor needs none).
    nonisolated static func hitArguments(_ point: CGPoint, select: Bool = true) -> PanelJSON {
        var arguments: [String: PanelJSON] = ["x": .number(Double(point.x)), "y": .number(Double(point.y))]
        if !select {
            arguments["select"] = .bool(false)
        }
        return .object(arguments)
    }

    /// The cursor `hitInfo` reports; nil for an error.
    nonisolated static func cursorKind(hitInfo answer: PanelJSON) -> CursorKind? {
        guard answer.panelErrorCode == nil, case .object = answer else { return nil }
        return CSSCursor.kind(keyword: answer["cursor"]?.stringValue ?? "auto",
                              editable: answer["editable"]?.boolValue ?? false,
                              link: answer["link"]?.boolValue ?? false)
    }

    /// `{x, y, width, height}` in CSS px; nil for anything else (null: nothing editable has focus).
    nonisolated static func rect(_ json: PanelJSON) -> CGRect? {
        guard let x = json["x"]?.doubleValue, let y = json["y"]?.doubleValue,
              let width = json["width"]?.doubleValue, let height = json["height"]?.doubleValue,
              x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

extension PanelJSON {

    /// An object's member; nil for a missing key, or for anything but an object.
    subscript(_ key: String) -> PanelJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    /// The panel script's `{error: {code, message}}`: its code.
    var panelErrorCode: String? {
        self["error"]?["code"]?.stringValue
    }
}
