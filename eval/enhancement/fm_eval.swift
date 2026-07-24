import Foundation
import FoundationModels

struct Fixture: Codable {
    let id: String
    let task: String
    let transcript: String
}

struct Result: Codable {
    let id: String
    let task: String
    let transcript: String
    let output: String
    let totalMs: Double
    let firstTokenMs: Double
    let error: String?
}

@main
struct FMEval {
    static func main() async {
        let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        let fixtures = try! JSONDecoder().decode([Fixture].self, from: Data(contentsOf: dir.appendingPathComponent("fixtures.json")))
        let prompts = try! JSONDecoder().decode([String: String].self, from: Data(contentsOf: dir.appendingPathComponent("prompts.json")))

        let base = SystemLanguageModel.default
        guard case .available = base.availability else {
            print("UNAVAILABLE: \(base.availability)")
            exit(2)
        }
        FileHandle.standardError.write("availability: available\n".data(using: .utf8)!)

        // Permissive guardrails for content transformation (transcripts may contain anything).
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

        // Warmup: one throwaway request so model is resident (mirrors prewarm-on-record-start).
        do {
            let warm = LanguageModelSession(model: model, instructions: prompts["cleanup"]!)
            let t0 = Date()
            _ = try await warm.respond(to: "Um hello there.")
            FileHandle.standardError.write("warmup (cold) ms: \(Date().timeIntervalSince(t0) * 1000)\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("warmup error: \(error)\n".data(using: .utf8)!)
        }

        var results: [Result] = []
        for f in fixtures {
            let session = LanguageModelSession(model: model, instructions: prompts[f.task]!)
            session.prewarm()
            let opts = GenerationOptions(temperature: 0.1)
            let t0 = Date()
            var firstTokenMs = -1.0
            do {
                var final = ""
                let stream = session.streamResponse(to: f.transcript, options: opts)
                for try await partial in stream {
                    if firstTokenMs < 0 { firstTokenMs = Date().timeIntervalSince(t0) * 1000 }
                    final = partial.content
                }
                let total = Date().timeIntervalSince(t0) * 1000
                results.append(Result(id: f.id, task: f.task, transcript: f.transcript, output: final, totalMs: total, firstTokenMs: firstTokenMs, error: nil))
                FileHandle.standardError.write("\(f.id): \(Int(total))ms\n".data(using: .utf8)!)
            } catch {
                let total = Date().timeIntervalSince(t0) * 1000
                results.append(Result(id: f.id, task: f.task, transcript: f.transcript, output: "", totalMs: total, firstTokenMs: firstTokenMs, error: "\(error)"))
                FileHandle.standardError.write("\(f.id): ERROR \(error)\n".data(using: .utf8)!)
            }
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try! enc.encode(results).write(to: dir.appendingPathComponent("results_fm.json"))
        print("wrote results_fm.json")
    }
}
