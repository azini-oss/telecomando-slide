import AppKit

let arguments = CommandLine.arguments
if arguments.contains("--selftest") || arguments.contains("--selftest-nav") {
    SelfTest.run(navigate: arguments.contains("--selftest-nav"))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
