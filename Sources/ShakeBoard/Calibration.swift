import AppKit

protocol CalibrationCancellable: AnyObject {
    func cancel()
}

extension DispatchWorkItem: CalibrationCancellable {}

@MainActor
final class CalibrationSession {
    typealias EventHandler = (NSEvent) -> NSEvent?
    typealias AddLocalMonitor = (@escaping EventHandler) -> Any?
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> CalibrationCancellable

    private let addLocalMonitor: AddLocalMonitor
    private let removeMonitor: (Any) -> Void
    private let schedule: Schedule
    private let beginTracking: () -> Void
    private let endTracking: () -> Void
    private let onProgress: (Int) -> Void
    private let onFinish: (Int, CGFloat) -> Void

    private var monitor: Any?
    private var scheduledFinish: CalibrationCancellable?
    private var samples: [CGFloat] = []
    private var lastReportedReversals = 0
    private(set) var isRecording = false

    init(
        addLocalMonitor: @escaping AddLocalMonitor,
        removeMonitor: @escaping (Any) -> Void,
        schedule: @escaping Schedule,
        beginTracking: @escaping () -> Void,
        endTracking: @escaping () -> Void,
        onProgress: @escaping (Int) -> Void,
        onFinish: @escaping (Int, CGFloat) -> Void
    ) {
        self.addLocalMonitor = addLocalMonitor
        self.removeMonitor = removeMonitor
        self.schedule = schedule
        self.beginTracking = beginTracking
        self.endTracking = endTracking
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func start() {
        guard !isRecording else { return }
        isRecording = true
        samples = []
        lastReportedReversals = 0
        onProgress(0)
        beginTracking()
        monitor = addLocalMonitor { [weak self] event in
            self?.record(deltaX: event.deltaX)
            return event
        }
        scheduledFinish = schedule(2.5) { [weak self] in self?.finish() }
    }

    func record(deltaX: CGFloat) {
        guard isRecording else { return }
        samples.append(deltaX)
        let reversals = Self.analyze(samples).reversals
        guard reversals != lastReportedReversals else { return }
        lastReportedReversals = reversals
        onProgress(reversals)
    }

    func cancel() {
        guard isRecording else { return }
        stop()
    }

    func finish() {
        guard isRecording else { return }
        let result = Self.analyze(samples)
        stop()
        onFinish(result.reversals, result.swing)
    }

    private func stop() {
        isRecording = false
        scheduledFinish?.cancel()
        scheduledFinish = nil
        if let monitor { removeMonitor(monitor) }
        monitor = nil
        endTracking()
        samples = []
    }

    static func analyze(_ samples: [CGFloat]) -> (reversals: Int, swing: CGFloat) {
        var accum: CGFloat = 0
        var direction = 0
        var reversals = 0
        var swings: [CGFloat] = []
        for delta in samples {
            accum += delta
            if abs(accum) >= 25 {
                let newDirection = accum > 0 ? 1 : -1
                if direction != 0, newDirection != direction {
                    reversals += 1
                    swings.append(abs(accum))
                }
                direction = newDirection
                accum = 0
            }
        }
        let average = swings.isEmpty ? 60 : swings.reduce(0, +) / CGFloat(swings.count)
        return (reversals, average)
    }
}
