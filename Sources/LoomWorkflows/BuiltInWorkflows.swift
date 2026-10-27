import Foundation

/// What a new library starts with: the PR review in three passes and the
/// experts it dispatches to — copies the user edits, renames, deletes.
/// Prompts in English like every prompt claude reads; the answers in French,
/// the language the report is read in.
public enum BuiltInWorkflows {

    public static let prReviewID = UUID(uuidString: "0B1E5D3A-2C4F-4A6B-8D9E-7F1A2B3C4D01")!

    enum ExpertID {
        static let analyst = UUID(uuidString: "0B1E5D3A-2C4F-4A6B-8D9E-7F1A2B3C4E01")!
        static let php = UUID(uuidString: "0B1E5D3A-2C4F-4A6B-8D9E-7F1A2B3C4E02")!
        static let symfony = UUID(uuidString: "0B1E5D3A-2C4F-4A6B-8D9E-7F1A2B3C4E03")!
        static let security = UUID(uuidString: "0B1E5D3A-2C4F-4A6B-8D9E-7F1A2B3C4E04")!
        static let tests = UUID(uuidString: "0B1E5D3A-2C4F-4A6B-8D9E-7F1A2B3C4E05")!
        static let lead = UUID(uuidString: "0B1E5D3A-2C4F-4A6B-8D9E-7F1A2B3C4E06")!
    }

    static let reviewRules = """
    You review a pull request in a read-only checkout of its head. Never modify a file, commit, push, or post anything to GitHub or Jira. Verify every finding against the code before keeping it; when unsure, say so with a low confidence rather than inventing. Write every text value in French.
    """

    public static let experts: [Expert] = [
        Expert(id: ExpertID.analyst, name: "Analyste fonctionnel", domain: "Besoin, ticket, intention",
               systemPrompt: reviewRules + "\n\nYou are a senior functional analyst. You read tickets and pull requests to state what is really asked and what the change really does, without judging the code style.",
               model: "sonnet", color: "#0D6E74"),
        Expert(id: ExpertID.php, name: "Expert PHP", domain: "PHP",
               systemPrompt: reviewRules + "\n\nYou are a PHP expert (PHP 8.x): types and strictness, null handling, error handling and exceptions, performance pitfalls, PSR conventions, Composer dependencies. Stay in your domain: leave framework and security matters to the other experts.",
               color: "#4F5B93"),
        Expert(id: ExpertID.symfony, name: "Expert Symfony", domain: "Symfony",
               systemPrompt: reviewRules + "\n\nYou are a Symfony expert: services and dependency injection, configuration, Doctrine (entities, migrations, queries, N+1), Messenger, forms and validation, security voters, events, cache. Stay in your domain.",
               color: "#1E1E1E"),
        Expert(id: ExpertID.security, name: "Expert sécurité", domain: "Sécurité applicative",
               systemPrompt: reviewRules + "\n\nYou are an application security reviewer: injection, access control, authentication, secrets, unsafe deserialization, SSRF, XSS, CSRF, data exposure in logs and responses. Report only what a realistic attacker can reach.",
               color: "#A61A16"),
        Expert(id: ExpertID.tests, name: "Expert tests", domain: "Tests et qualité",
               systemPrompt: reviewRules + "\n\nYou are a testing expert: what the change needs covered, whether the tests touched actually test it, missing edge cases, flaky patterns. Run the relevant tests when the project makes that cheap.",
               color: "#007153"),
        Expert(id: ExpertID.lead, name: "Lead reviewer", domain: "Cohérence et synthèse",
               systemPrompt: reviewRules + "\n\nYou are the lead reviewer. You check the experts' findings against the code and against each other: drop what does not hold, merge duplicates, resolve contradictions, and keep severities honest.",
               model: "opus", color: "#E22C22"),
    ]

    static let findingFields: [OutputField] = [
        OutputField("summary", .text, "Two to four sentences: what you checked and what you think."),
        OutputField("findings", .list, """
        Objects {"title", "severity": "blocking"|"fix"|"minor", "path", "line", "detail", "suggestion", "confidence": 0-1}. path and line point at the new code when they can.
        """),
    ]

    static func expertPrompt(_ domain: String) -> String {
        """
        Review pull request #{{pr.number}} — "{{pr.title}}" — for its \(domain) aspects only. Pass {{iteration}}.

        What it is for (from the analyst):
        {{steps.intent.intent}}

        Ticket criteria:
        {{steps.intent.ticketCriteria}}

        Reading order:
        {{steps.intent.readingOrder}}

        Files touched:
        {{steps.pr.files}}

        Read the diff with `gh pr diff {{pr.number}}` and the code around it in the checkout.

        The lead reviewer's consolidated review of the previous pass (empty on the first pass): check whether its points hold, answer its questions to you, and do not repeat what it already settled.
        {{previous.coherence}}
        """
    }

    public static func prReview(atlassian: UUID = Connector.atlassianRemoteID) -> Workflow {
        func agent(_ id: String, _ title: String, expert: UUID, prompt: String, output: [OutputField],
                   x: Double, y: Double) -> WorkflowNode {
            WorkflowNode(id: id, title: title, position: Position(x: x, y: y),
                         kind: .agent(AgentConfig(expertID: expert, prompt: prompt, output: output)))
        }
        let experts: [(String, String, UUID, String)] = [
            ("php", "Expert PHP", ExpertID.php, "PHP"),
            ("symfony", "Expert Symfony", ExpertID.symfony, "Symfony"),
            ("security", "Sécurité", ExpertID.security, "security"),
            ("tests", "Tests", ExpertID.tests, "testing"),
        ]
        var nodes: [WorkflowNode] = [
            WorkflowNode(id: "start", title: "Démarrage", position: Position(x: 0, y: 260),
                         kind: .start(StartConfig(triggers: [.manual, .pullRequest, .schedule]))),
            WorkflowNode(id: "pr", title: "La PR", position: Position(x: 260, y: 120),
                         kind: .context(ContextConfig(source: .pullRequest))),
            WorkflowNode(id: "ticket", title: "Le ticket Jira", position: Position(x: 260, y: 260),
                         kind: .context(ContextConfig(source: .jiraTicket, connectorIDs: [atlassian]))),
            WorkflowNode(id: "repo", title: "Le repo", position: Position(x: 260, y: 400),
                         kind: .context(ContextConfig(source: .repository))),
            agent("intent", "Intentions", expert: ExpertID.analyst, prompt: """
            Read pull request #{{pr.number}} — "{{pr.title}}" ({{pr.url}}) — and its ticket, then state its intentions.

            The PR:
            {{steps.pr.text}}

            The ticket {{ticket.key}}:
            {{steps.ticket.text}}

            The repository:
            {{steps.repo.text}}

            Explore the checkout as much as you need (`gh pr diff {{pr.number}}`, the touched files and their callers).
            """, output: [
                OutputField("intent", .text, "What the PR means to achieve, in three to five lines."),
                OutputField("readingOrder", .list, "Objects {\"path\", \"why\"}: the order to read the files in, the heart of the change first."),
                OutputField("ticketCriteria", .list, "Objects {\"criterion\", \"status\": \"ok\"|\"partial\"|\"missing\", \"evidence\"}: each acceptance criterion and how the diff covers it. Empty without a ticket."),
                OutputField("risks", .list, "Short strings: where the change could hurt."),
                OutputField("questions", .list, "Short strings: what the code alone cannot settle.", required: false),
            ], x: 540, y: 260),
        ]
        for (index, expert) in experts.enumerated() {
            nodes.append(agent(expert.0, expert.1, expert: expert.2, prompt: expertPrompt(expert.3),
                               output: findingFields, x: 840, y: Double(60 + index * 140)))
        }
        nodes.append(agent("coherence", "Cohérence", expert: ExpertID.lead, prompt: """
        Pass {{iteration}} of the review of pull request #{{pr.number}} — "{{pr.title}}".

        Intent: {{steps.intent.intent}}

        The experts' findings this pass:
        - PHP: {{steps.php.text}}
        - Symfony: {{steps.symfony.text}}
        - Security: {{steps.security.text}}
        - Tests: {{steps.tests.text}}

        Your consolidated review of the previous pass (empty on the first pass):
        {{previous.coherence}}

        Check each finding against the code. Keep what holds, drop what does not, merge duplicates, settle contradictions. The review is stable when this pass changed nothing that matters compared with the previous one, or when there is nothing left to check.
        """, output: [
            OutputField("stable", .boolean, "true when another pass would not change the review."),
            OutputField("verdict", .text, "\"approve\", \"request_changes\" or \"comment\"."),
            OutputField("summary", .text, "The review in four to eight lines, for the PR's author."),
            OutputField("findings", .list, "The consolidated findings, same objects as the experts', each with an \"expert\" key."),
            OutputField("dropped", .list, "Objects {\"title\", \"why\"}: findings you rejected.", required: false),
            OutputField("changes", .text, "What this pass changed compared with the previous one.", required: false),
        ], x: 1140, y: 260))
        nodes.append(WorkflowNode(id: "loop", title: "Nouvelle passe ?", position: Position(x: 1400, y: 260),
                                  kind: .loop(LoopConfig(targets: experts.map { $0.0 }, maxIterations: 2,
                                                         stopWhen: Condition(path: "steps.coherence.stable", op: .isTrue)))))
        nodes.append(WorkflowNode(id: "report", title: "Rapport", position: Position(x: 1660, y: 260),
                                  kind: .artifact(ArtifactConfig(template: "pr-review", theme: "current",
                                                                 title: "{{pr.title}}", importToPRTab: true))))
        var edges = [WorkflowEdge(from: "start", to: "pr"), WorkflowEdge(from: "start", to: "ticket"),
                     WorkflowEdge(from: "start", to: "repo"), WorkflowEdge(from: "pr", to: "intent"),
                     WorkflowEdge(from: "ticket", to: "intent"), WorkflowEdge(from: "repo", to: "intent")]
        for expert in experts {
            edges.append(WorkflowEdge(from: "intent", to: expert.0))
            edges.append(WorkflowEdge(from: expert.0, to: "coherence"))
        }
        edges += [WorkflowEdge(from: "coherence", to: "loop"), WorkflowEdge(from: "loop", to: "report")]
        return Workflow(id: prReviewID, name: "PR review — 3 passes",
                        summary: "Ticket, PR et repo lus, intentions notées, quatre experts en parallèle, cohérence vérifiée jusqu'à trois passes, rapport final.",
                        tags: ["review", "pr"], color: "#E22C22", nodes: nodes, edges: edges,
                        orchestrator: prReviewOrchestrator)
    }

    /// The lead reviewer conducts the review (ADR-0018): it watches each
    /// expert's answer and steers before the report.
    public static let prReviewOrchestrator = OrchestratorConfig(
        expertID: ExpertID.lead, instructions: """
        This run reviews PR #{{pr.number}} — {{pr.title}}.
        - After the intentions step, check they match the PR and the ticket; ask the analyst when something is unclear.
        - After each expert, check its findings are anchored (path and line) and in its domain. A vague or \
        off-domain answer: ask it one precise question, or rerun it with precise instructions.
        - Before the report, read the consolidated review: every blocking finding must hold. Rerun `coherence` \
        if one does not, then proceed.
        - Keep the person informed in a few lines: what you checked, what you changed.
        """, maxInterventions: 10, maxRerunsPerStep: 1, reviewBeforeArtifact: true)

    public static let connectors: [Connector] = [Connector.atlassianRemote(), Connector.atlassianStdio()]
}
