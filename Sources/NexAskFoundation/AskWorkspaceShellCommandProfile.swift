import Foundation

package struct AskWorkspaceShellCommandProfile: Equatable, Sendable {
    package let rawCommand: String
    package let normalizedCommand: String
    package let mutatesWorkspace: Bool
    package let requiresGitWriteActions: Bool
    package let requiresNetworkAccess: Bool

    package init(command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        self.rawCommand = trimmed
        self.normalizedCommand = normalized

        let gitWritePatterns = Self.gitWritePatterns
        let networkPatterns = Self.networkPatterns
        let mutationPatterns = Self.mutationPatterns

        let requiresGitWriteActions = Self.matchesAny(patterns: gitWritePatterns, in: normalized)
        let requiresNetworkAccess =
            Self.matchesAny(patterns: networkPatterns, in: normalized)
            || normalized.contains("http://")
            || normalized.contains("https://")
        let mutatesWorkspace =
            requiresGitWriteActions
            || Self.matchesAny(patterns: mutationPatterns, in: normalized)
            || Self.containsRedirection(in: normalized)

        self.mutatesWorkspace = mutatesWorkspace
        self.requiresGitWriteActions = requiresGitWriteActions
        self.requiresNetworkAccess = requiresNetworkAccess
    }

    private static let gitWritePatterns = [
        "git add ",
        "git am",
        "git apply",
        "git branch ",
        "git cherry-pick",
        "git checkout ",
        "git clean",
        "git commit",
        "git merge",
        "git pull",
        "git push",
        "git rebase",
        "git reset",
        "git revert",
        "git stash",
        "git switch ",
        "git tag "
    ]

    private static let networkPatterns = [
        "brew install",
        "brew update",
        "cargo add",
        "cargo install",
        "curl ",
        "gh api",
        "gh auth ",
        "gem install",
        "git clone",
        "git fetch",
        "git pull",
        "git push",
        "go get",
        "go install",
        "npm add",
        "npm install",
        "npx ",
        "pip install",
        "pnpm add",
        "pnpm dlx",
        "pnpm install",
        "pod install",
        "uv pip install",
        "wget ",
        "yarn add",
        "yarn install"
    ]

    private static let mutationPatterns = [
        "chmod ",
        "chown ",
        "cp ",
        "dd ",
        "install ",
        "ln ",
        "mkdir ",
        "mv ",
        "patch ",
        "perl -pi",
        "rm ",
        "sed -i",
        "tee ",
        "touch ",
        "truncate "
    ]

    private static func matchesAny(patterns: [String], in command: String) -> Bool {
        patterns.contains { command.contains($0) }
    }

    private static func containsRedirection(in command: String) -> Bool {
        guard command.contains(">") else {
            return false
        }
        if command.contains("2>") || command.contains("1>") {
            return true
        }
        return command.contains(" >") || command.contains(">>")
    }
}
