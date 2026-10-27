import Foundation

/// Instructions every claude session Loom starts or resumes receives, appended
/// to its system prompt (`--append-system-prompt`): how to keep its Loom
/// session readable through the agents API, and whatever the user adds over
/// time. Global, where a project's rules live in its own CLAUDE.md. English,
/// like every prompt claude reads; the text is the user's to edit in Settings.
public enum SessionInstructions {

    public static let defaultText = """
    You run inside Loom, a macOS app that hosts each agent session in its own terminal and lists the sessions side by side. Loom gives you its API as the `loom` MCP server (tools named `loom_*`); when those tools are missing, the `loom` command in your shell does the same (`loom docs` prints the reference).

    Keep your Loom session readable at a glance:
    - Once you know what the user wants, name the session after the task with `loom_session_set_title`: a few words, specific ("Fix flaky cache test", not "Coding"). Rename it when the task changes. Leave the title alone in a session wearing a "PR #n" badge: Loom names its review sessions.
    - Use badges for the session's status: `loom_badge_list` shows the catalog, `loom_session_set_badges` sets them (keep the badges already there, a "PR #n" one included). Create a badge with `loom_badge_create` only when none fits.
    - `loom_session_get` tells you your session's state, branch and worktree.
    """
}
