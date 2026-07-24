import Foundation
import FoundationModels

@Generable
struct Cleaned: Codable {
    @Guide(description: "The cleaned-up transcript text only. Plain prose, never code, never markdown code fences.")
    let cleanedText: String
}

struct Fixture: Codable { let id: String; let task: String; let transcript: String }

@main
struct FMGuided {
    static func main() async {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtures = try! JSONDecoder().decode([Fixture].self, from: Data(contentsOf: dir.appendingPathComponent("fixtures.json")))
        let prompts = try! JSONDecoder().decode([String: String].self, from: Data(contentsOf: dir.appendingPathComponent("prompts.json")))
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        _ = try? await LanguageModelSession(model: model, instructions: prompts["cleanup"]!).respond(to: "Um hi.")
        for f in fixtures {
            let session = LanguageModelSession(model: model, instructions: prompts[f.task]!)
            let t0 = Date()
            do {
                let r = try await session.respond(to: f.transcript, generating: Cleaned.self, options: GenerationOptions(temperature: 0.1))
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                print("== \(f.id) (\(ms)ms)\nOUT: \(r.content.cleanedText)\n")
            } catch {
                print("== \(f.id) ERROR: \(error)\n")
            }
        }
    }
}
