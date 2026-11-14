//
//  main.swift
//  3ds2apple — iOS Simulator runtime harness
//
//  This is a tiny, non-shipping app whose only job is to drive the real
//  Zakuro runtime inside the iOS Simulator: it finds a ROM in the app's
//  Documents/roms, calls zk_create / zk_run_frame / zk_read_screen and shows
//  the two 3DS screens. The shipping SwiftUI shell (ios/app) cannot be driven
//  head-less (it needs a library tap), so the build VM uses this harness to
//  prove the x86_64 simulator static library (build-ios-zakuro-sim.sh) really
//  boots a game and renders frames.
//
//  Everything is logged twice: to Documents/sim-harness.log (pulled out with
//  "xcrun simctl get_app_container <udid> com.kratos.3ds2apple.sim data") and
//  to os_log/NSLog (visible with "xcrun simctl spawn <udid> log stream").
//
//  Build with scripts/build-ios-app-sim.sh --app harness; see
//  docs/build-simulator.md.
//

import CoreGraphics
import Darwin
import Metal
import SwiftUI
import UIKit

// MARK: - File logger

final class SimLog {
    static let shared = SimLog()
    private static let started = Date()
    private let url: URL
    private let lock = NSLock()
    private let handle: FileHandle?

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = docs.appendingPathComponent("sim-harness.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        log("=== 3ds2apple sim harness starting ===")
    }

    var path: String { url.path }

    /// Last lines of the log, for the on-screen tail in the harness UI.
    func tail(maxLines: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    func log(_ message: String) {
        let elapsed = String(format: "%.3f", Date().timeIntervalSince(SimLog.started))
        let line = "[sim +\(elapsed)s] \(message)\n"
        lock.lock()
        if let handle, let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
            try? handle.synchronize()
        }
        lock.unlock()
        NSLog("%@", line.trimmingCharacters(in: .newlines))
        print(line, terminator: "")
    }
}

// MARK: - Runtime model

final class HarnessModel: ObservableObject {
    @Published var status = "starting"
    @Published var topImage: UIImage?
    @Published var bottomImage: UIImage?
    @Published var logTail = ""

    private let runtimeQueue = DispatchQueue(label: "com.kratos.3ds2apple.sim.runtime")
    private let documents: URL
    private var started = false
    private var systemHandle: zk_system_t?
    /// dlopen() handle of the embedded per-game GamePack dylib, if any; kept
    /// open for the whole run because its AOT tables stay registered.
    private var gamepackHandle: UnsafeMutableRawPointer?

    init() {
        documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func start() {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true
        publish("starting")
        runtimeQueue.async { [weak self] in
            self?.run()
        }
    }

    /// Press A for ~120 ms: enough for the boot "press A" prompts of common
    /// titles, and proof that zk_set_input reaches the interpreter.
    func pressA() {
        runtimeQueue.async { [weak self] in
            guard let system = self?.systemHandle else { return }
            SimLog.shared.log("input: press A")
            zk_set_input(system, UInt32(1), 0, 0, 0, 0, 0)
            Thread.sleep(forTimeInterval: 0.12)
            zk_set_input(system, UInt32(0), 0, 0, 0, 0, 0)
        }
    }

    // MARK: runtime worker

    private func run() {
        log("documents: \(documents.path)")
        log("log file: \(SimLog.shared.path)")
        probeMetal()
        loadGamePack()

        guard let rom = findROM() else {
            log("rom: no .cci/.3ds in Documents/roms (seed one and relaunch)")
            publish("no ROM in Documents/roms")
            return
        }

        let dataDir = documents.appendingPathComponent("data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        log("zk_create: loading \(rom.lastPathComponent) (\(fileSize(rom)) bytes) with data dir \(dataDir.path)")
        publish("zk_create…")
        let createStart = Date()
        guard let system = zk_create(rom.path, dataDir.path) else {
            log("zk_create: FAILED after \(fmt(Date().timeIntervalSince(createStart))) s: \(lastRuntimeError())")
            publish("zk_create failed")
            return
        }
        systemHandle = system
        log("zk_create: OK after \(fmt(Date().timeIntervalSince(createStart))) s")
        let recompiled = zk_recompiled(system)
        log(String(format: "zk_recompiled: %d (1 = Zakuro is running AOT code)", recompiled))
        log(String(format: "zk_linked_program_id: %016llX", zk_linked_program_id()))
        log("zk_linked_code: \(zk_linked_code()) (1 = AOT code is available to this build)")
        guard recompiled == 1 else {
            // This harness exists to prove the AOT path; an interpreter fallback
            // means the pack did not register, so stop instead of logging frames.
            log("AOT: not active (zk_recompiled=0); refusing to run interpreted code")
            publish("AOT not active (recompiled=0)")
            zk_destroy(system)
            systemHandle = nil
            return
        }

        let topWidth = Int(zk_screen_width(0))
        let topHeight = Int(zk_screen_height(0))
        let bottomWidth = Int(zk_screen_width(1))
        let bottomHeight = Int(zk_screen_height(1))
        log("screens: top=\(topWidth)x\(topHeight) bottom=\(bottomWidth)x\(bottomHeight)")
        guard topWidth > 0, topHeight > 0, bottomWidth > 0, bottomHeight > 0 else {
            log("screens: invalid geometry; aborting")
            publish("bad screen geometry")
            return
        }

        let topPixels = UnsafeMutablePointer<UInt8>.allocate(capacity: topWidth * topHeight * 4)
        let bottomPixels = UnsafeMutablePointer<UInt8>.allocate(capacity: bottomWidth * bottomHeight * 4)
        defer {
            topPixels.deallocate()
            bottomPixels.deallocate()
            systemHandle = nil
            zk_destroy(system)
            log("zk_destroy: runtime released")
        }

        var frames = 0
        var savedFrames = 0
        var statusLogged = false
        var windowStart = Date()
        var windowMinMs = Double.greatestFiniteMagnitude
        var windowMaxMs = 0.0
        var windowFrames = 0
        var firstFrameLogged = false
        let pngFrames: Set<Int> = [5, 30, 120, 300, 600, 1200]
        var savedPngFrames = Set<Int>()

        while true {
            let frameStart = Date()
            let result = zk_run_frame(system)
            let frameMs = Date().timeIntervalSince(frameStart) * 1000
            if result != 0 {
                log("frame: zk_run_frame -> \(result) after \(frames) frames")
                publish("runtime stopped (\(result)) after \(frames) frames")
                break
            }
            frames += 1
            windowFrames += 1
            // AOT coverage evidence: after 60 frames ask the runtime how much
            // of the executed instruction stream came from the recompiled code.
            if frames == 60 && !statusLogged {
                statusLogged = true
                if let status = zk_recompiled_status(system) {
                    log("zk_recompiled_status: \(String(cString: status))")
                } else {
                    log("zk_recompiled_status: no text returned")
                }
            }
            windowMinMs = min(windowMinMs, frameMs)
            windowMaxMs = max(windowMaxMs, frameMs)

            if !firstFrameLogged {
                firstFrameLogged = true
                log("frame: first frame rendered (\(fmt(frameMs)) ms)")
            }

            if frames <= 3 || frames % 2 == 0 {
                let topBytes = zk_read_screen(system, 0, topPixels, topWidth * topHeight * 4)
                let bottomBytes = zk_read_screen(system, 1, bottomPixels, bottomWidth * bottomHeight * 4)
                if frames <= 2 {
                    log("read_screen: top=\(topBytes) bottom=\(bottomBytes) bytes")
                    log("read_screen: top mean=\(meanLuma(topPixels, count: topBytes)) bottom mean=\(meanLuma(bottomPixels, count: bottomBytes))")
                }
                if let top = image(from: topPixels, width: topWidth, height: topHeight),
                   let bottom = image(from: bottomPixels, width: bottomWidth, height: bottomHeight) {
                    DispatchQueue.main.async { [weak self] in
                        self?.topImage = top
                        self?.bottomImage = bottom
                    }
                }
                if pngFrames.contains(frames), !savedPngFrames.contains(frames) {
                    savedPngFrames.insert(frames)
                    savePNG(from: topPixels, width: topWidth, height: topHeight, name: "top-frame\(frames).png")
                    savePNG(from: bottomPixels, width: bottomWidth, height: bottomHeight, name: "bottom-frame\(frames).png")
                    savedFrames += 1
                }
            }

            let now = Date()
            if now.timeIntervalSince(windowStart) >= 1.0 {
                let fps = Double(windowFrames) / now.timeIntervalSince(windowStart)
                log(String(format: "perf: frames=%d fps=%.2f frame_min=%.2fms frame_max=%.2fms frame_avg=%.2fms",
                           frames, fps, windowMinMs, windowMaxMs,
                           now.timeIntervalSince(windowStart) >= 0 && windowFrames > 0
                               ? (now.timeIntervalSince(windowStart) * 1000 / Double(windowFrames)) : 0))
                publish(String(format: "running: %d frames, %.1f fps", frames, fps))
                windowStart = now
                windowFrames = 0
                windowMinMs = Double.greatestFiniteMagnitude
                windowMaxMs = 0
            }
        }
        log("run: finished with \(frames) frames, \(savedFrames) saved png steps")
    }

    // MARK: GamePack (AOT-first proof)

    /// Loads the per-game GamePack dylib the simulator build embeds under
    /// Frameworks/ and lets it register its AOT code with this harness's
    /// runtime. The shipping shell's AOTPackageLoader does the same checks
    /// (title id, ABI version, registration hook); the harness mirrors them so
    /// the pack path can be proven headless, without tapping the library.
    private func loadGamePack() {
        let frameworks = Bundle.main.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil)) ?? []
        let packs = urls.filter { $0.pathExtension == "dylib" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        log("gamepack: candidates=\(packs.map { $0.lastPathComponent })")
        guard !packs.isEmpty else {
            log("gamepack: none in the app bundle; this run exercises the interpreter-only runtime")
            return
        }
        // Mirrors AOTPackageLoader: a pack is usable when it loads, states its
        // title and ABI, and accepts the host ABI through its registration hook.
        // Packs that fail are skipped (the shell reports that catalog entry as
        // unavailable); the first one that registers is the AOT code this run uses.
        for pack in packs {
            guard let handle = dlopen(pack.path, RTLD_NOW | RTLD_LOCAL) else {
                let detail = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
                log("gamepack: \(pack.lastPathComponent): dlopen FAILED: \(detail)")
                continue
            }
            log("gamepack: \(pack.lastPathComponent): dlopen OK")
            if let symbol = dlsym(handle, "zk_gamepack_title_id") {
                typealias TitleIDFunction = @convention(c) () -> UInt64
                let titleID = unsafeBitCast(symbol, to: TitleIDFunction.self)()
                log(String(format: "gamepack: \(pack.lastPathComponent): title id %016llX", titleID))
            } else {
                log("gamepack: \(pack.lastPathComponent): no zk_gamepack_title_id export")
            }
            if let symbol = dlsym(handle, "zk_gamepack_abi_version") {
                typealias ABIVersionFunction = @convention(c) () -> UInt32
                let abi = unsafeBitCast(symbol, to: ABIVersionFunction.self)()
                log("gamepack: \(pack.lastPathComponent): pack ABI \(abi) (host ABI 1)")
            } else {
                log("gamepack: \(pack.lastPathComponent): no zk_gamepack_abi_version export")
            }
            guard let symbol = dlsym(handle, "zk_gamepack_register") else {
                log("gamepack: \(pack.lastPathComponent): no zk_gamepack_register export; skipped")
                dlclose(handle)
                continue
            }
            typealias RegisterFunction = @convention(c) (UInt32) -> Int32
            let result = unsafeBitCast(symbol, to: RegisterFunction.self)(1)
            guard result == 0 else {
                log("gamepack: \(pack.lastPathComponent): registration refused (result \(result)); skipped")
                dlclose(handle)
                continue
            }
            gamepackHandle = handle
            log("gamepack: \(pack.lastPathComponent): registered with the runtime; AOT code is active")
            return
        }
        log("gamepack: no pack registered; this run has no AOT code")
    }

    // MARK: helpers

    // Test-only harness hook: the runtime exposes a human-readable AOT status that
    // includes the interpreted-instruction percentage (zk_recompiled_status). The
    // shipping bridge header does not declare it because the app never shows raw
    // runtime counters; the harness logs it to prove AOT coverage after frames ran.
    @_silgen_name("zk_recompiled_status")
    private func zk_recompiled_status(_ system: zk_system_t?) -> UnsafePointer<CChar>?

    private func probeMetal() {
        let device = MTLCreateSystemDefaultDevice()
        log("metal: MTLCreateSystemDefaultDevice=\(device?.name ?? "nil")")
        if #available(iOS 18.0, *) {
            log("metal: MTLCopyAllDevices=\(MTLCopyAllDevices().map { $0.name })")
        } else {
            log("metal: MTLCopyAllDevices unavailable before iOS 18")
        }
        log("metal: ProcessInfo.simulator=\(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "no")")
    }

    private func findROM() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        for directory in [documents.appendingPathComponent("roms"), documents] {
            guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for url in items {
                let ext = url.pathExtension.lowercased()
                if ext == "cci" || ext == "3ds" { candidates.append(url) }
            }
        }
        let sorted = candidates.sorted { $0.lastPathComponent < $1.lastPathComponent }
        log("rom: candidates=\(sorted.map { $0.lastPathComponent })")
        return sorted.first
    }

    private func image(from pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> UIImage? {
        let count = width * height * 4
        let data = Data(bytes: pixels, count: count)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func savePNG(from pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, name: String) {
        guard let image = image(from: pixels, width: width, height: height),
              let png = image.pngData() else { return }
        let directory = documents.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        do {
            try png.write(to: url)
            log("png: saved \(url.path) (\(png.count) bytes)")
        } catch {
            log("png: could not save \(name): \(error)")
        }
    }

    private func meanLuma(_ pixels: UnsafeMutablePointer<UInt8>, count: Int) -> String {
        var sum = 0
        var nonZero = 0
        let stride = max(1, count / 1000)
        var sampled = 0
        var i = 0
        while i + 3 < count {
            let value = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
            sum += value
            if value > 12 { nonZero += 1 }
            sampled += 1
            i += stride
        }
        guard sampled > 0 else { return "n/a" }
        return String(format: "%.1f nonzero=%d/%d", Double(sum) / Double(sampled) / 3.0, nonZero, sampled)
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// zk_last_error() is thread-local: read and copy it on the runtime queue.
    private func lastRuntimeError() -> String {
        if let error = zk_last_error() {
            return String(cString: error)
        }
        return "nil"
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func log(_ message: String) {
        SimLog.shared.log(message)
    }

    private func publish(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.status = text
            self?.logTail = SimLog.shared.tail(maxLines: 12)
        }
    }
}

// MARK: - UI

struct HarnessView: View {
    @ObservedObject var model: HarnessModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("3ds2apple · simulator runtime").font(.headline)
                Spacer()
                Text(model.status).font(.caption).foregroundColor(.yellow)
            }
            screen(model.topImage, aspect: 400.0 / 240.0, label: "top 400x240")
            screen(model.bottomImage, aspect: 320.0 / 240.0, label: "bottom 320x240")
            Text(model.logTail)
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Press A") { model.pressA() }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
        .foregroundColor(.green)
    }

    @ViewBuilder
    private func screen(_ image: UIImage?, aspect: CGFloat, label: String) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(aspect, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.green.opacity(0.4), lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
                .aspectRatio(aspect, contentMode: .fit)
                .overlay(Text(label).font(.caption2).foregroundColor(.gray))
        }
    }
}

@main
struct SimHarnessApp: App {
    @StateObject private var model = HarnessModel()

    var body: some Scene {
        WindowGroup {
            HarnessView(model: model)
                .onAppear { model.start() }
        }
    }
}
