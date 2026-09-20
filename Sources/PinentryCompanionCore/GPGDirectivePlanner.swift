import Foundation

struct GPGDirectiveChange {
    var action: PlanAction
    var beforeValues: [String]
    var updatedContents: String
    var conflict: PlanConflict?
}

enum GPGDirectivePlanner {
    static func plan(
        contents: String,
        exists: Bool,
        invokedPath: String,
        resolvedPath: String,
        allowTakeover: Bool = false
    ) throws -> GPGDirectiveChange {
        let values = GPGAgentConfig.activePinentryPrograms(in: contents)
        let hasForeignValue = values.contains {
            !PassiveStatusBuilder.pathsMatch(
                $0,
                invokedPath: invokedPath,
                resolvedPath: resolvedPath
            )
        }

        if hasForeignValue && !allowTakeover {
            return GPGDirectiveChange(
                action: .blocked,
                beforeValues: values,
                updatedContents: contents,
                conflict: PlanConflict(
                    code: "foreignPinentryProgram",
                    message: "The active pinentry-program does not resolve to this binary."
                )
            )
        }

        let action: PlanAction
        if hasForeignValue {
            action = .replace
        } else if values.isEmpty {
            action = exists ? .add : .create
        } else if values.count == 1 {
            action = .none
        } else {
            action = .deduplicate
        }

        return GPGDirectiveChange(
            action: action,
            beforeValues: values,
            updatedContents: action == .none
                ? contents
                : try GPGAgentConfig.updatedContents(contents, pinentryPath: invokedPath),
            conflict: nil
        )
    }
}
