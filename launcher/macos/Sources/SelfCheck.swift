//
//  SelfCheck.swift
//  3ds2apple macOS launcher
//
//  Headless logic self-checks: parsers, manifest mapping, push ordering, error
//  translation and a full mock import -> build -> push flow. This is the
//  launcher test evidence on the VM, where XCTest cannot run (there is no GUI
//  session and no testmanagerd):
//
//     3ds2apple-launcher --selfcheck
//
//  Exit code 0 = every check passed, 1 = at least one failure.
//

import Foundation

@MainActor
enum SelfCheck {
    struct Check {
        var name: String
        var passed: Bool
        var detail: String
    }

    static func runHeadless() -> Never {
        Task { @MainActor in
            let checks = await runAll()
            for check in checks {
                let prefix = check.passed ? "PASS  " : "FAIL  "
                print(prefix + check.name + (check.detail.isEmpty ? "" : "  [" + check.detail + "]"))
            }
            let failed = checks.filter { !$0.passed }
            print("")
            print(String(checks.count - failed.count) + "/" + String(checks.count) + " launcher self-checks passed")
            exit(failed.isEmpty ? 0 : 1)
        }
        RunLoop.main.run()
        exit(1)
    }

    static func runAll() async -> [Check] {
        var checks: [Check] = []
        checks.append(contentsOf: await SelfCheckCore.checks())
        checks.append(contentsOf: await SelfCheckFlow.checks())
        checks.append(contentsOf: SelfCheckLocalization.checks())
        return checks
    }
}
