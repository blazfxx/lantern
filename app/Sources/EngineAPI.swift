// Talks to the Erebus engine: spawns `erebus serve` for a database and speaks its local JSON API.
import Foundation

// MARK: - Models (mirror the engine's JSON)

struct Part: Codable { let t: String; let a: String? }          // text + optional clickable address
struct PseudoPart: Codable { let t: String; let c: String; let a: String? }

struct Insn: Codable {
    let a: String
    let z: Int
    let b: String
    let m: String
    let o: [Part]
    let c: [Part]
    let p: Bool?
    let label: String?
}
struct Block: Codable { let a: String; let end: String; let label: String; let from: [String]; let insns: [Insn] }
struct Edge: Codable { let s: String; let d: String; let k: Int }   // k: 0 fall, 1 jump, 2 true, 3 false
struct XrefItem: Codable { let a: String; let n: String; let t: String }
struct FuncDetail: Codable {
    let a: String; let end: String; let n: String; let size: Int
    let noret: Bool; let thunk: Bool
    let blocks: [Block]; let edges: [Edge]; let xrefs: [XrefItem]
}
struct LinearListing: Codable { let insns: [Insn]; let next: String }
struct PseudoLine: Codable { let i: Int; let p: [PseudoPart] }
struct PseudoResult: Codable { let a: String; let lines: [PseudoLine] }
struct SegmentInfo: Codable { let name: String; let a: String; let size: UInt64; let perms: Int }
struct BinaryInfo: Codable {
    let file: String; let format: String; let arch: String; let bits: Int
    let base: String; let entry: String; let entryName: String
    let funcs: Int; let blocks: Int; let insns: Int; let xrefs: Int; let names: Int; let strings: Int
    let codeBytes: UInt64; let covered: UInt64
    let segments: [SegmentInfo]
}
struct ListItem: Codable { let a: String; let n: String; let x: String? }
struct FuncItem: Codable { let a: String; let n: String; let s: Int; let t: Bool; let r: Bool }
struct ListResult<T: Codable>: Codable { let total: Int; let items: [T] }
struct XrefResult: Codable { let a: String; let n: String; let items: [XrefItem] }
struct HexResult: Codable { let a: String; let n: String; let hex: String }
struct WhereResult: Codable { let a: String; let n: String; let `func`: String; let code: Bool; let mapped: Bool }
struct CallNode: Codable { let a: String; let n: String; let c: [CallNode] }
struct PatchInfo: Codable { let a: String; let n: String; let orig: String; let new: String }
struct PatchList: Codable { let items: [PatchInfo] }
struct FindResult: Codable { let items: [FindHit] }
struct FindHit: Codable { let a: String; let n: String }
struct OK: Codable { let ok: Bool? }
struct ErrorBody: Codable { let error: String }

enum EngineError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

// MARK: - Process management

final class EngineProcess {
    static var binaryPath: String? {
        let fm = FileManager.default
        var c: [String] = []
        if let env = ProcessInfo.processInfo.environment["LANTERN_ENGINE"] { c.append(env) }
        if let res = Bundle.main.resourcePath { c.append(res + "/bin/erebus") }
        c.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path + "/erebus")
        c.append("/opt/homebrew/bin/erebus"); c.append("/usr/local/bin/erebus")
        return c.first { fm.isExecutableFile(atPath: $0) }
    }

    static func run(_ args: [String]) -> (status: Int32, out: String, err: String) {
        guard let bin = binaryPath else { return (-1, "", "engine not found") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin); p.arguments = args
        let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
        do { try p.run() } catch { return (-1, "", "\(error)") }
        let od = o.fileHandleForReading.readDataToEndOfFile(), ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self))
    }

    static var version: String { run(["--version"]).out.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var proc: Process?
    private(set) var baseURL: URL?

    /// Starts `erebus serve <db>` on a free port; calls back with the URL (or an error).
    func start(database: URL, completion: @escaping (Result<URL, EngineError>) -> Void) {
        guard let bin = EngineProcess.binaryPath else { return completion(.failure(.message("The Erebus engine was not found."))) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["serve", database.path, "--port", "0", "--no-open", "--watch-pid", String(getpid())]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        final class State: @unchecked Sendable { var buf = ""; var done = false }
        let state = State()
        nonisolated(unsafe) let cb = completion
        nonisolated(unsafe) let owner = self
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            state.buf += String(decoding: d, as: UTF8.self)
            if !state.done, let r = state.buf.range(of: #"http://127\.0\.0\.1:\d+"#, options: .regularExpression), let u = URL(string: String(state.buf[r])) {
                state.done = true; h.readabilityHandler = nil; owner.baseURL = u; cb(.success(u))
            }
        }
        do { try p.run(); proc = p } catch { completion(.failure(.message("Could not start the engine: \(error)"))) }
    }

    func stop() { if let p = proc, p.isRunning { p.terminate() }; proc = nil }
    deinit { stop() }
}

// MARK: - API client

final class EngineAPI: @unchecked Sendable {
    let base: URL
    private let session = URLSession(configuration: .ephemeral)
    init(base: URL) { self.base = base }

    private func request<T: Decodable>(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> T {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        if let body = body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "HTTP \(http.statusCode)"
            throw EngineError.message(msg)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func info() async throws -> BinaryInfo { try await request("api/info") }
    func funcs(_ q: String = "", limit: Int = 5000) async throws -> ListResult<FuncItem> { try await request("api/funcs", query: ["q": q, "limit": String(limit)]) }
    func list(_ kind: String, _ q: String = "") async throws -> ListResult<ListItem> { try await request("api/list", query: ["kind": kind, "q": q]) }
    func function(_ a: String) async throws -> FuncDetail { try await request("api/func", query: ["a": a]) }
    func linear(_ a: String, n: Int = 200) async throws -> LinearListing { try await request("api/lin", query: ["a": a, "n": String(n)]) }
    func pseudo(_ a: String) async throws -> PseudoResult { try await request("api/pseudo", query: ["a": a]) }
    func xrefs(_ a: String) async throws -> XrefResult { try await request("api/xrefs", query: ["a": a]) }
    func hex(_ a: String, n: Int = 512) async throws -> HexResult { try await request("api/hex", query: ["a": a, "n": String(n)]) }
    func whereIs(_ a: String) async throws -> WhereResult { try await request("api/where", query: ["a": a]) }
    func callgraph(_ a: String, depth: Int = 2) async throws -> CallNode { try await request("api/callgraph", query: ["a": a, "d": String(depth)]) }
    func patches() async throws -> PatchList { try await request("api/patches") }
    func find(hex: String? = nil, text: String? = nil) async throws -> FindResult {
        var q: [String: String] = [:]; if let h = hex { q["hex"] = h }; if let t = text { q["text"] = t }
        return try await request("api/find", query: q)
    }
    @discardableResult func rename(_ a: String, _ name: String) async throws -> OK { try await request("api/rename", body: ["a": a, "name": name]) }
    @discardableResult func comment(_ a: String, _ text: String) async throws -> OK { try await request("api/comment", body: ["a": a, "text": text]) }
    @discardableResult func patch(_ a: String, hex: String) async throws -> OK { try await request("api/patch", body: ["a": a, "hex": hex]) }
    @discardableResult func assemble(_ a: String, _ text: String) async throws -> OK { try await request("api/asm", body: ["a": a, "text": text]) }
    @discardableResult func unpatch(_ a: String) async throws -> OK { try await request("api/unpatch", body: ["a": a]) }
    @discardableResult func reanalyze() async throws -> OK { try await request("api/reanalyze", body: [:]) }
    @discardableResult func export(_ path: String, sign: Bool) async throws -> OK { try await request("api/export", body: ["path": path, "sign": sign]) }
}
