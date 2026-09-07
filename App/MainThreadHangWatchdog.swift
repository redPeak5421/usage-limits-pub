import Darwin
import Foundation
import UsageLimitsCore

/// 主线程卡顿看门狗（排查真机「首次打开 / 切主题必卡」用，DEVLOG #89）。
///
/// 后台线程每 100 ms 往主队列投一个心跳；超过 `thresholdMilliseconds` 没回来，就向主线程发 SIGPROF，
/// 在信号处理函数里用 `backtrace` 把主线程当时的调用栈抓进静态缓冲区；主线程恢复后，把卡顿时长和栈
/// 写进探针诊断日志（`hang:` 前缀）。Release 包已剥符号，栈只记「镜像名 + 相对偏移」，
/// 用归档里的 dSYM 符号化：`atos -o UsageLimits.app.dSYM/Contents/Resources/DWARF/UsageLimits -arch arm64 -l 0x100000000 0x1000XXXXX`
///（主可执行文件 __TEXT 基址 0x100000000，地址 = 基址 + 偏移）。
///
/// 只读、只记日志、每次卡顿只抓一次栈，对正常运行没有可感知开销。
final class MainThreadHangWatchdog {
    static let shared = MainThreadHangWatchdog()

    private static let thresholdMilliseconds = 300.0
    private static let pingInterval: useconds_t = 100_000
    private static let maxFrames = 48

    private let lock = NSLock()
    private var mainThread: pthread_t?
    private var pingInFlight = false
    private var pingSentAt: CFAbsoluteTime = 0
    private var stackCaptured = false
    private var capturedOffsets: [String] = []
    private var thread: Thread?

    /// 必须在主线程调用（要记住主线程的 pthread）。
    func start() {
        guard Thread.isMainThread, thread == nil else { return }
        mainThread = pthread_self()
        Self.installSignalHandler()
        let worker = Thread { [weak self] in
            self?.runLoop()
        }
        worker.name = "usagelimits.hang-watchdog"
        worker.qualityOfService = .utility
        worker.start()
        thread = worker
    }

    // MARK: - 看门狗循环

    private func runLoop() {
        while true {
            usleep(Self.pingInterval)
            let now = CFAbsoluteTimeGetCurrent()
            var shouldCapture = false
            var stalledFor = 0.0
            lock.lock()
            if pingInFlight {
                stalledFor = (now - pingSentAt) * 1000
                if stalledFor >= Self.thresholdMilliseconds, !stackCaptured {
                    stackCaptured = true
                    shouldCapture = true
                }
            } else {
                pingInFlight = true
                pingSentAt = now
                DispatchQueue.main.async { [weak self] in
                    self?.pong()
                }
            }
            lock.unlock()

            if shouldCapture {
                captureMainThreadStack()
            }
        }
    }

    private func pong() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let stalled = (now - pingSentAt) * 1000
        let offsets = capturedOffsets
        let hadStack = stackCaptured
        pingInFlight = false
        stackCaptured = false
        capturedOffsets = []
        lock.unlock()

        guard hadStack || stalled >= Self.thresholdMilliseconds else { return }
        let milliseconds = Int(stalled.rounded())
        if offsets.isEmpty {
            SharedStore.shared.appendDiagnostic("hang: \(milliseconds) ms (no stack)")
        } else {
            SharedStore.shared.appendDiagnostic("hang: \(milliseconds) ms | main stack: " + offsets.joined(separator: " "))
        }
        print("hang: \(milliseconds) ms | \(offsets.joined(separator: " "))")
    }

    /// 向主线程发 SIGPROF，等处理函数写完缓冲区，再把地址翻成「镜像+偏移」。
    private func captureMainThreadStack() {
        guard let mainThread else { return }
        hangCaptureDone = 0
        pthread_kill(mainThread, SIGPROF)
        var waited = 0
        while hangCaptureDone == 0, waited < 200 {
            usleep(1_000)
            waited += 1
        }
        guard hangCaptureDone != 0 else { return }
        let count = Int(hangFrameCount)
        var offsets: [String] = []
        offsets.reserveCapacity(count)
        for index in 0..<min(count, Self.maxFrames) {
            guard let address = hangFrameBuffer[index] else { continue }
            var info = Dl_info()
            if dladdr(address, &info) != 0, let base = info.dli_fbase {
                let module = info.dli_fname.map { String(cString: $0) }.map { ($0 as NSString).lastPathComponent } ?? "?"
                let offset = UInt(bitPattern: address) - UInt(bitPattern: base)
                offsets.append("\(module)+0x\(String(offset, radix: 16))")
            } else {
                offsets.append("0x\(String(UInt(bitPattern: address), radix: 16))")
            }
        }
        lock.lock()
        capturedOffsets = offsets
        lock.unlock()
    }

    private static func installSignalHandler() {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = hangSignalHandler
        action.sa_flags = SA_RESTART
        sigemptyset(&action.sa_mask)
        sigaction(SIGPROF, &action, nil)
    }
}

// MARK: - 信号处理函数用的静态缓冲区（处理函数里不能分配内存、不能拿锁）

private let hangFrameBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
private var hangFrameCount: Int32 = 0
private var hangCaptureDone: Int32 = 0

private func hangSignalHandler(_ signal: Int32) {
    hangFrameCount = backtrace(hangFrameBuffer, 64)
    hangCaptureDone = 1
}
