import Foundation

let nodes = [UINode(id: 1, role: "AXTextField", label: "Name", value: "Ada", actions: ["set_text"]),
             UINode(id: 2, role: "AXButton", label: "Save", value: "", actions: ["press"])]
func check(_ action: String, _ target: Int, _ text: String, accepted: Bool) {
    let proposal = AgentAction(action: action, target: target, text: text, reason: "Test")
    do {
        try proposal.validate(nodes: nodes)
        precondition(accepted, "Accepted invalid action \(action), target \(target)")
    } catch { precondition(!accepted, "Rejected valid action: \(error)") }
}
check("press", 2, "", accepted: true)
check("set_text", 1, "Grace", accepted: true)
check("done", 0, "", accepted: true)
check("blocked", 0, "", accepted: true)
check("press", 999, "", accepted: false)
check("press", 1, "", accepted: false)
check("set_text", 2, "oops", accepted: false)
check("press", 2, "extra", accepted: false)
check("set_text", 1, "Ada", accepted: false)
check("done", 2, "", accepted: false)
check("shell", 0, "rm", accepted: false)
check("set_text", 1, String(repeating: "x", count: 4001), accepted: false)
print("PASS: 12 action validation checks")
