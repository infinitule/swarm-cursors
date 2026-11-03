import Foundation

struct UINode: Codable, Equatable {
    let id: Int
    let role: String
    let label: String
    let value: String
    let actions: [String]
}

struct AgentAction: Codable {
    let action: String
    let target: Int
    let text: String
    let reason: String

    func validate(nodes: [UINode]) throws {
        guard ["press", "set_text", "done", "blocked"].contains(action) else {
            throw AgentError.message("Unknown action. Nothing executed.")
        }
        if action == "done" || action == "blocked" {
            guard target == 0 && text.isEmpty else {
                throw AgentError.message("Invalid completion response. Nothing executed.")
            }
            return
        }
        guard let node = nodes.first(where: { $0.id == target }), node.actions.contains(action) else {
            throw AgentError.message("Model selected a missing or unsupported target. Nothing executed.")
        }
        guard text.count <= 4000 else { throw AgentError.message("Replacement text is too long.") }
        if action == "press" && !text.isEmpty {
            throw AgentError.message("Invalid button action: model supplied extra text. Nothing executed.")
        }
        if action == "set_text" && node.value == text {
            throw AgentError.message("Model proposed an edit already present. Observe and replan.")
        }
    }
}

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct PlanResult {
    let action: AgentAction
    let seconds: Double
    let tokensPerSecond: Double
}

// Never follow redirects: desktop UI data stays at this loopback endpoint.
final class LocalOnlySession: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class Planner {
    private let delegate = LocalOnlySession()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    private var task: URLSessionDataTask?

    func cancel() { task?.cancel(); task = nil }

    func plan(model: String, goal: String, nodes: [UINode], thinking: Bool, resourceDirectory: URL,
              completion: @escaping (Result<PlanResult, Error>) -> Void) {
        cancel()
        do {
            let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: resourceDirectory.appendingPathComponent("action-schema.json")))
            let system = try String(contentsOf: resourceDirectory.appendingPathComponent("planner-system.txt"), encoding: .utf8)
            let nodeObjects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(nodes))
            let promptData = try JSONSerialization.data(withJSONObject: ["goal": goal, "ui": nodeObjects], options: [.sortedKeys])
            guard promptData.count < 18000 else {
                throw AgentError.message("This window has too much text for the small planner. Narrow the window or task.")
            }
            let payload: [String: Any] = ["model": model, "system": system,
                "prompt": String(decoding: promptData, as: UTF8.self), "format": schema,
                "stream": false, "think": thinking, "keep_alive": "10m",
                "options": ["temperature": 0, "num_ctx": 8192, "num_predict": thinking ? 768 : 160]]
            var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let start = Date()
            task = session.dataTask(with: request) { data, response, error in
                let result: Result<PlanResult, Error> = Result {
                    if let error = error { throw error }
                    guard let data = data, let response = response as? HTTPURLResponse else {
                        throw AgentError.message("No response from local Ollama.")
                    }
                    guard response.statusCode == 200 else {
                        throw AgentError.message("Ollama returned HTTP \(response.statusCode). Check that the model is installed.")
                    }
                    guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let content = body["response"] as? String else {
                        throw AgentError.message("Ollama did not return an action.")
                    }
                    let action = try JSONDecoder().decode(AgentAction.self, from: Data(content.utf8))
                    try action.validate(nodes: nodes)
                    let tokens = (body["eval_count"] as? Double) ?? 0
                    let duration = ((body["eval_duration"] as? Double) ?? 0) / 1e9
                    return PlanResult(action: action, seconds: Date().timeIntervalSince(start),
                                      tokensPerSecond: duration > 0 ? tokens / duration : 0)
                }
                DispatchQueue.main.async { completion(result) }
            }
            task?.resume()
        } catch { completion(.failure(error)) }
    }
}
