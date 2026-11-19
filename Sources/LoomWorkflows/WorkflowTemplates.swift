import Foundation
import LoomCore

/// A workflow ready to use (ADR-0021): shown in the Workflows tab, copied
/// into the library when the person picks it. The library itself starts
/// empty — a template is an offer, never something Loom installs on its own.
public struct WorkflowTemplate: Identifiable, Sendable {
    /// Stable (`ship-task`): the agents API and ⌘K name a template by it.
    public let id: String
    public let name: String
    /// One line: what a run leaves behind.
    public let tagline: String
    /// How a run goes, a few short lines.
    public let highlights: [String]
    /// An SF Symbol.
    public let icon: String
    /// What the Run sheet writes in its task field, as an example.
    public let taskPlaceholder: String
    private let make: @Sendable () -> WorkflowBundle

    init(id: String, name: String, tagline: String, highlights: [String], icon: String,
         taskPlaceholder: String = "", make: @escaping @Sendable () -> WorkflowBundle) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.highlights = highlights
        self.icon = icon
        self.taskPlaceholder = taskPlaceholder
        self.make = make
    }

    /// The workflow with the experts it needs. Each call is a new workflow
    /// (its own id): a template may be used twice. Its experts keep their
    /// ids — a library that already has one keeps its own, edits included.
    public func bundle() -> WorkflowBundle { make() }

    /// The workflow as the gallery draws it, before anyone picks it.
    public var preview: Workflow { make().workflow }
}

public enum WorkflowTemplates {

    public static let all: [WorkflowTemplate] = [shipTask, fixChecks, reviewPullRequest, investigate]

    public static func template(_ id: String) -> WorkflowTemplate? { all.first { $0.id == id } }

    // MARK: Experts

    enum ExpertID {
        static let developer = UUID(uuidString: "7A2C9E10-5B3D-4F6A-9C1E-0D4B8A6F2E01")!
        static let reviewer = UUID(uuidString: "7A2C9E10-5B3D-4F6A-9C1E-0D4B8A6F2E02")!
        static let investigator = UUID(uuidString: "7A2C9E10-5B3D-4F6A-9C1E-0D4B8A6F2E03")!
        static let analyst = UUID(uuidString: "7A2C9E10-5B3D-4F6A-9C1E-0D4B8A6F2E04")!
        static let security = UUID(uuidString: "7A2C9E10-5B3D-4F6A-9C1E-0D4B8A6F2E05")!
        static let tests = UUID(uuidString: "7A2C9E10-5B3D-4F6A-9C1E-0D4B8A6F2E06")!
        static let lead = UUID(uuidString: "7A2C9E10-5B3D-4F6A-9C1E-0D4B8A6F2E07")!
    }

    static let language = "Write every text you answer in the language of the task you were given (French when in doubt)."

    /// Writes code, in the run's own worktree.
    public static let developer = Expert(
        id: ExpertID.developer, name: "Développeur", domain: "Écrit le code, sur la branche du run",
        systemPrompt: """
        You are a senior developer working in a git worktree of your own, on a branch made for this run. \
        Nobody else works there: change what the task needs, and nothing else.
        - Read before you write: the project's instructions (CLAUDE.md, README, CONTRIBUTING), then the code \
        around what you touch. Follow its conventions rather than yours.
        - Keep the diff small and on the task. No drive-by refactoring, no reformatting of lines you did not need to change.
        - Prove it works: run the project's own checks (tests, linter, type check, build) the way this repository \
        runs them, and fix what you broke. Never skip, disable or weaken a test to make it pass. Report the \
        commands you ran and what they gave, failures included.
        - Stay on this branch. Never push, never open a pull request, never touch another branch or the \
        project's main checkout: the person decides what leaves this worktree.
        \(language)
        """,
        allowedTools: Expert.workTools, color: "#2F6FDE")

    /// Reads what was done, with fresh eyes; writes nothing.
    public static let reviewer = Expert(
        id: ExpertID.reviewer, name: "Relecteur", domain: "Relit le travail d'un autre, sans rien modifier",
        systemPrompt: """
        You review work you did not write. You change nothing: no file, no commit, no push. \
        Judge the change against what was asked, then against the code around it:
        - Does it do the task — all of it, and only it?
        - Is it correct: edge cases, error paths, concurrency, what the callers expect?
        - Is it proven: do the tests exercise the change, or merely pass beside it?
        Verify each finding in the code before you keep it; one you could not verify is said to be a doubt, \
        with a low confidence. Point at a file and a line whenever you can. Praise is not a finding.
        \(language)
        """,
        allowedTools: Expert.readOnlyTools, color: "#B4541A")

    public static let investigator = Expert(
        id: ExpertID.investigator, name: "Enquêteur", domain: "Remonte d'un symptôme à sa cause, sans rien modifier",
        systemPrompt: """
        You investigate a problem in a codebase. You change nothing. Go from the symptom to the code that \
        produces it: follow the call paths, read the history (`git log`, `git blame`) where it explains a \
        choice, and tell apart what you saw in the code from what you suppose. Every claim about the code \
        names a file and a line. When two causes are possible, say what would tell them apart.
        \(language)
        """,
        allowedTools: Expert.readOnlyTools, color: "#6E56CF")

    static let reviewRules = """
    You review a pull request in a read-only checkout of its head. Never modify a file, commit, push, or post \
    anything to GitHub. Verify every finding against the code before keeping it; when unsure, say so with a low \
    confidence rather than inventing. Write every text value in the language the pull request is written in \
    (French when in doubt).
    """

    public static let analyst = Expert(
        id: ExpertID.analyst, name: "Analyste", domain: "Ce que la PR veut faire, et dans quel ordre la lire",
        systemPrompt: reviewRules + "\n\nYou are a senior analyst. You read a pull request to state what it "
            + "really means to achieve and what it really does, without judging the code style.",
        model: "sonnet", allowedTools: Expert.readOnlyTools, color: "#0D6E74")

    public static let security = Expert(
        id: ExpertID.security, name: "Sécurité", domain: "Sécurité applicative",
        systemPrompt: reviewRules + "\n\nYou are an application security reviewer: injection, access control, "
            + "authentication, secrets, unsafe deserialization, SSRF, XSS, CSRF, data exposure in logs and "
            + "responses. Report only what a realistic attacker can reach.",
        allowedTools: Expert.readOnlyTools, color: "#A61A16")

    public static let tests = Expert(
        id: ExpertID.tests, name: "Tests", domain: "Tests et maintenabilité",
        systemPrompt: reviewRules + "\n\nYou are a testing and maintainability reviewer: what the change needs "
            + "covered, whether the tests touched actually test it, missing edge cases, flaky patterns, and code "
            + "the next person will not be able to change safely.",
        allowedTools: Expert.readOnlyTools, color: "#007153")

    public static let lead = Expert(
        id: ExpertID.lead, name: "Lead", domain: "Vérifie, recoupe et tranche",
        systemPrompt: reviewRules + "\n\nYou are the lead reviewer. You check the reviewers' findings against the "
            + "code and against each other: drop what does not hold, merge duplicates, resolve contradictions, "
            + "and keep severities honest.",
        model: "opus", allowedTools: Expert.readOnlyTools, color: "#E22C22")

    // MARK: Shared pieces

    static let findingFields: [OutputField] = [
        OutputField("summary", .text, "Two to four sentences: what you checked and what you think."),
        OutputField("findings", .list, """
        Objects {"title", "severity": "blocking"|"fix"|"minor", "path", "line", "detail", "suggestion", "confidence": 0-1}. \
        path and line point at the new code when they can. Empty when nothing is wrong.
        """),
    ]

    static let reviewVerdict = VerdictConfig(
        options: ["ok", "à revoir"],
        guidance: "\"ok\" when the task is done as asked and nothing you found has to be fixed before a person "
            + "looks at it; \"à revoir\" when at least one finding must be fixed first.")

    static func node(_ id: String, _ title: String, x: Double, y: Double = 200, _ kind: NodeKind) -> WorkflowNode {
        WorkflowNode(id: id, title: title, position: Position(x: x, y: y), kind: kind)
    }

    // MARK: Réaliser une tâche

    /// Plan → your go → implementation → an independent review that sends
    /// the work back — on a branch of the run's own.
    public static let shipTask = WorkflowTemplate(
        id: "ship-task", name: "Réaliser une tâche",
        tagline: "Une tâche en entrée, une branche relue en sortie.",
        highlights: [
            "Un développeur explore le code et propose un plan — rien n'est modifié avant ton accord.",
            "Il implémente sur une branche dédiée, lance les vérifications du projet et commite.",
            "Un relecteur indépendant relit le diff ; « à revoir » renvoie le travail, deux fois au plus.",
        ],
        icon: "hammer", taskPlaceholder: "Ajouter un export CSV à la page des factures, avec les mêmes filtres que la liste.") {
        let nodes = [
            node("start", "Démarrage", x: 0, .start(StartConfig(triggers: [.manual]))),
            node("plan", "Plan", x: 260, .agent(AgentConfig(
                expertID: ExpertID.developer,
                prompt: """
                You start a task in this repository, in a worktree of your own on the branch `{{run.branch}}`.

                The task:
                {{run.task}}

                Do not change any file yet. Explore the code as much as you need, then write the plan: what you \
                will change and where, in the order you will do it, and how you will check that it works (which \
                tests, which commands). Keep it short enough to be read in a minute. If the task cannot be done \
                without an answer from the person, put the question in `questions` rather than guessing.
                """,
                output: [
                    OutputField("plan", .text, "The plan as short Markdown: numbered steps, each naming the files it touches."),
                    OutputField("files", .list, "Strings: the files you expect to change or create."),
                    OutputField("checks", .text, "How you will verify the work: the commands you will run."),
                    OutputField("questions", .list, "Strings: what only the person can settle. Empty when nothing is.", required: false),
                ],
                mode: .visible, timeoutSeconds: 1800, continues: "plan"))),
            node("go", "Ton accord", x: 520, .approval(ApprovalConfig(
                question: """
                {{steps.plan.plan}}

                Vérifications prévues : {{steps.plan.checks}}

                Questions ouvertes :
                {{steps.plan.questions}}
                """,
                options: ["go", "à revoir", "arrêter"]))),
            node("implement", "Implémentation", x: 780, .agent(AgentConfig(
                expertID: ExpertID.developer,
                prompt: """
                The plan is approved: implement it now, in this worktree (branch `{{run.branch}}`).

                The person's comment on the plan (may be empty): {{steps.go.comment}}

                - Make the changes the plan describes, and keep the diff on the task.
                - Run the project's own checks (tests, linter, type check, build) and fix what you broke.
                - Commit your work on this branch with a clear message. Do not push; do not open a pull request.

                A reviewer who has not seen your work reads the diff next. Their review of the previous round \
                (empty the first time) — fix what it found, and say what you did about each point:
                {{previous.review}}
                """,
                output: [
                    OutputField("summary", .text, "What you changed and why, in a few lines."),
                    OutputField("filesChanged", .list, "Strings: the files you changed or created."),
                    OutputField("checks", .text, "The commands you ran and what each gave — failures included."),
                    OutputField("notes", .text, "What is left to do or to know, if anything.", required: false),
                ],
                mode: .visible, timeoutSeconds: 3600, continues: "plan"))),
            node("review", "Relecture", x: 1040, .agent(AgentConfig(
                expertID: ExpertID.reviewer,
                prompt: """
                Review the work done for this task, in the worktree you are in (branch `{{run.branch}}`).

                The task:
                {{run.task}}

                The plan that was approved:
                {{steps.plan.plan}}

                What the developer reports:
                {{steps.implement.text}}

                Read what changed since the run started: `git status`, `git log --oneline {{run.base}}..HEAD`, \
                `git diff {{run.base}}`, then the code around it. Your own review of the previous round (empty \
                the first time) — check each point was dealt with, and do not raise again what was settled:
                {{previous.review}}
                """,
                output: findingFields, timeoutSeconds: 1200, verdict: reviewVerdict))),
            node("report", "Rapport", x: 1300, .artifact(ArtifactConfig(template: "generic", title: "{{run.title}}"))),
        ]
        let edges = [
            WorkflowEdge(from: "start", to: "plan"),
            WorkflowEdge(from: "plan", to: "go"),
            WorkflowEdge(from: "go", to: "implement", when: "go"),
            WorkflowEdge(from: "go", to: "report", otherwise: true),
            WorkflowEdge(from: "go", to: "plan", when: "à revoir", retry: RetryConfig(max: 2),
                         rules: ["Revise the plan with the person's comment; say what you changed in it."]),
            WorkflowEdge(from: "implement", to: "review"),
            WorkflowEdge(from: "review", to: "report"),
            WorkflowEdge(from: "review", to: "implement", when: "à revoir", retry: RetryConfig(max: 2),
                         rules: ["Fix every finding of the review, or say precisely why one does not hold."]),
        ]
        let workflow = Workflow(
            name: "Réaliser une tâche",
            summary: "Plan validé par toi, implémentation sur une branche dédiée, relecture indépendante qui renvoie le travail s'il le faut.",
            tags: ["dev", "branche"], color: "#2F6FDE", nodes: nodes, edges: edges, workspace: .worktree)
        return WorkflowBundle(workflow: workflow, experts: [developer, reviewer], connectors: [])
    }

    // MARK: Corriger jusqu'au vert

    /// One developer keeps at a failing check until it passes, then a
    /// reviewer makes sure green was not bought by weakening the checks.
    public static let fixChecks = WorkflowTemplate(
        id: "fix-checks", name: "Corriger jusqu'au vert",
        tagline: "Des tests ou un build en échec en entrée, une branche verte en sortie.",
        highlights: [
            "Le développeur reproduit l'échec, corrige, relance — trois tours au plus, dans la même conversation.",
            "Un relecteur vérifie que le vert n'a pas été obtenu en désactivant ou en affaiblissant un test.",
            "Tout se passe sur une branche dédiée : ton dossier de travail ne bouge pas.",
        ],
        icon: "checkmark.seal", taskPlaceholder: "`npm test` échoue sur la suite checkout depuis la montée de version de stripe-js.") {
        let nodes = [
            node("start", "Démarrage", x: 0, .start(StartConfig(triggers: [.manual]))),
            node("fix", "Correction", x: 260, .agent(AgentConfig(
                expertID: ExpertID.developer,
                prompt: """
                Something fails in this repository; you work on it in a worktree of your own (branch `{{run.branch}}`).

                What fails, in the person's words:
                {{run.task}}

                Round {{iteration}}. Reproduce the failure first: run the check and read what it says. Find the \
                cause in the code — not in the test, unless the test itself is wrong, and then say why. Fix it, \
                run the check again, and run the rest of the project's checks to see you broke nothing. Commit on \
                this branch; do not push.

                Answer "vert" only when the failing check passes for a reason you can explain; otherwise \
                "encore rouge", with what you tried and what you would try next.

                A reviewer's remarks on your previous fix (empty the first time):
                {{previous.review}}
                """,
                output: [
                    OutputField("cause", .text, "The cause of the failure, with the file and line."),
                    OutputField("fix", .text, "What you changed."),
                    OutputField("checks", .text, "The commands you ran and what each gave."),
                ],
                mode: .visible, timeoutSeconds: 3600,
                verdict: VerdictConfig(options: ["vert", "encore rouge"],
                                       guidance: "\"vert\" when the check that failed now passes and the others still do."),
                continues: "fix"))),
            node("review", "Relecture", x: 520, .agent(AgentConfig(
                expertID: ExpertID.reviewer,
                prompt: """
                A developer fixed a failing check in the worktree you are in (branch `{{run.branch}}`).

                What failed:
                {{run.task}}

                What the developer reports:
                {{steps.fix.text}}

                Read the fix: `git log --oneline {{run.base}}..HEAD`, `git diff {{run.base}}`. Make sure green was \
                earned: no test skipped, deleted or loosened, no assertion weakened, no error swallowed, no check \
                removed from the configuration — and that the fix treats the cause rather than its symptom. \
                Your previous review (empty the first time):
                {{previous.review}}
                """,
                output: findingFields, timeoutSeconds: 1200, verdict: reviewVerdict))),
            node("report", "Rapport", x: 780, .artifact(ArtifactConfig(template: "generic", title: "{{run.title}}"))),
        ]
        let edges = [
            WorkflowEdge(from: "start", to: "fix"),
            WorkflowEdge(from: "fix", to: "review", when: "vert"),
            WorkflowEdge(from: "fix", to: "report", otherwise: true),
            WorkflowEdge(from: "fix", to: "fix", when: "encore rouge", retry: RetryConfig(max: 2),
                         rules: ["Change your approach: what you tried last round did not work."]),
            WorkflowEdge(from: "review", to: "report"),
            WorkflowEdge(from: "review", to: "fix", when: "à revoir", retry: RetryConfig(max: 1),
                         rules: ["Redo the fix without what the review refused."]),
        ]
        let workflow = Workflow(
            name: "Corriger jusqu'au vert",
            summary: "Reproduit un échec (tests, lint, build), le corrige sur une branche dédiée et fait relire que le vert est mérité.",
            tags: ["dev", "tests", "branche"], color: "#007153", nodes: nodes, edges: edges, workspace: .worktree)
        return WorkflowBundle(workflow: workflow, experts: [developer, reviewer], connectors: [])
    }

    // MARK: Relire une PR

    /// Intent, then three reviewers side by side, then a lead who checks
    /// and decides — the report fills the PR's tab.
    public static let reviewPullRequest = WorkflowTemplate(
        id: "review-pr", name: "Relire une PR",
        tagline: "Une PR en entrée, une review vérifiée dans son onglet en sortie.",
        highlights: [
            "Un analyste dit ce que la PR veut faire et dans quel ordre la lire.",
            "Trois relecteurs en parallèle : exactitude, sécurité, tests.",
            "Un lead vérifie chaque retour dans le code, écarte ce qui ne tient pas et propose le verdict.",
        ],
        icon: "eye") {
        func agent(_ id: String, _ title: String, expert: UUID, prompt: String, output: [OutputField],
                   x: Double, y: Double) -> WorkflowNode {
            node(id, title, x: x, y: y, .agent(AgentConfig(expertID: expert, prompt: prompt, output: output)))
        }
        func reviewerPrompt(_ domain: String) -> String {
            """
            Review pull request #{{pr.number}} — "{{pr.title}}" — for \(domain) only.

            What it is for (from the analyst):
            {{steps.intent.intent}}

            Reading order:
            {{steps.intent.readingOrder}}

            Files touched:
            {{steps.pr.files}}

            Read the diff with `gh pr diff {{pr.number}}` and the code around it in the checkout.
            """
        }
        let reviewers: [(id: String, title: String, expert: UUID, domain: String)] = [
            ("correctness", "Exactitude", ExpertID.reviewer, "correctness: logic, edge cases, error handling, what the callers expect"),
            ("security", "Sécurité", ExpertID.security, "security"),
            ("tests", "Tests", ExpertID.tests, "tests and maintainability"),
        ]
        var nodes: [WorkflowNode] = [
            node("start", "Démarrage", x: 0, y: 260, .start(StartConfig(triggers: [.manual, .pullRequest, .schedule]))),
            node("pr", "La PR", x: 260, y: 180, .context(ContextConfig(source: .pullRequest))),
            node("repo", "Le dépôt", x: 260, y: 340, .context(ContextConfig(source: .repository))),
            agent("intent", "Intentions", expert: ExpertID.analyst, prompt: """
            Read pull request #{{pr.number}} — "{{pr.title}}" ({{pr.url}}) — and state its intentions.

            The PR:
            {{steps.pr.text}}

            The repository:
            {{steps.repo.text}}

            Explore the checkout as much as you need (`gh pr diff {{pr.number}}`, the touched files and their callers).
            """, output: [
                OutputField("intent", .text, "What the PR means to achieve, in three to five lines."),
                OutputField("readingOrder", .list, "Objects {\"path\", \"why\"}: the order to read the files in, the heart of the change first."),
                OutputField("risks", .list, "Short strings: where the change could hurt."),
                OutputField("questions", .list, "Short strings: what the code alone cannot settle.", required: false),
            ], x: 540, y: 260),
        ]
        for (index, reviewer) in reviewers.enumerated() {
            nodes.append(agent(reviewer.id, reviewer.title, expert: reviewer.expert,
                               prompt: reviewerPrompt(reviewer.domain), output: findingFields,
                               x: 840, y: Double(100 + index * 160)))
        }
        nodes.append(agent("synthesis", "Synthèse", expert: ExpertID.lead, prompt: """
        Consolidate the review of pull request #{{pr.number}} — "{{pr.title}}".

        Intent: {{steps.intent.intent}}

        The reviewers' findings:
        - Correctness: {{steps.correctness.text}}
        - Security: {{steps.security.text}}
        - Tests: {{steps.tests.text}}

        Check each finding against the code. Keep what holds, drop what does not, merge duplicates, settle \
        contradictions, and keep severities honest.
        """, output: [
            OutputField("verdict", .text, "\"approve\", \"request_changes\" or \"comment\"."),
            OutputField("summary", .text, "The review in four to eight lines, for the PR's author."),
            OutputField("findings", .list, "The consolidated findings, same objects as the reviewers', each with an \"expert\" key."),
            OutputField("dropped", .list, "Objects {\"title\", \"why\"}: findings you rejected.", required: false),
        ], x: 1140, y: 260))
        nodes.append(node("report", "Rapport", x: 1400, y: 260,
                          .artifact(ArtifactConfig(template: "pr-review", title: "{{pr.title}}", importToPRTab: true))))
        var edges = [
            WorkflowEdge(from: "start", to: "pr"), WorkflowEdge(from: "start", to: "repo"),
            WorkflowEdge(from: "pr", to: "intent"), WorkflowEdge(from: "repo", to: "intent"),
        ]
        for reviewer in reviewers {
            edges.append(WorkflowEdge(from: "intent", to: reviewer.id))
            edges.append(WorkflowEdge(from: reviewer.id, to: "synthesis"))
        }
        edges.append(WorkflowEdge(from: "synthesis", to: "report"))
        let workflow = Workflow(
            name: "Relire une PR",
            summary: "Intentions, trois relecteurs en parallèle (exactitude, sécurité, tests), un lead qui vérifie et tranche ; la review remplit l'onglet de la PR.",
            tags: ["review", "pr"], color: "#E22C22", nodes: nodes, edges: edges)
        return WorkflowBundle(workflow: workflow, experts: [analyst, reviewer, security, tests, lead], connectors: [])
    }

    // MARK: Enquêter sur un bug

    /// From a symptom to its cause, challenged once, written down — nothing
    /// is changed in the project.
    public static let investigate = WorkflowTemplate(
        id: "investigate", name: "Enquêter sur un bug",
        tagline: "Un symptôme en entrée, une cause prouvée et un plan de correction en sortie.",
        highlights: [
            "Un enquêteur remonte du symptôme au code, preuves à l'appui (fichier, ligne).",
            "Un second avis cherche ce qui contredit l'hypothèse ; « à creuser » relance l'enquête une fois.",
            "Lecture seule : rien n'est modifié. Le plan de correction se donne ensuite à « Réaliser une tâche ».",
        ],
        icon: "magnifyingglass", taskPlaceholder: "Après un changement de mot de passe, les anciennes sessions restent valides pendant plusieurs minutes.") {
        let nodes = [
            node("start", "Démarrage", x: 0, .start(StartConfig(triggers: [.manual]))),
            node("repo", "Le dépôt", x: 260, .context(ContextConfig(source: .repository))),
            node("inquiry", "Enquête", x: 520, .agent(AgentConfig(
                expertID: ExpertID.investigator,
                prompt: """
                Find the cause of this problem. Round {{iteration}}.

                The symptom, in the person's words:
                {{run.task}}

                The repository:
                {{steps.repo.text}}

                Go from the symptom to the code that produces it. Read as much as you need. Say what you saw \
                and what you only suppose; name the file and the line of every claim.

                A second opinion on your previous round (empty the first time) — answer its objections with \
                evidence, or change your conclusion:
                {{previous.challenge}}
                """,
                output: [
                    OutputField("cause", .text, "The cause, in a few lines someone new to the code can follow."),
                    OutputField("evidence", .list, "Objects {\"path\", \"line\", \"what\"}: what in the code shows it."),
                    OutputField("fixPlan", .text, "How to fix it: the changes, in order, and the test that would have caught it."),
                    OutputField("confidence", .number, "0 to 1: how sure you are of the cause."),
                    OutputField("unknowns", .list, "Strings: what you could not establish from the code alone.", required: false),
                ],
                timeoutSeconds: 1500, continues: "inquiry"))),
            node("challenge", "Second avis", x: 780, .agent(AgentConfig(
                expertID: ExpertID.reviewer,
                prompt: """
                Someone investigated this problem; try to prove them wrong.

                The symptom:
                {{run.task}}

                Their conclusion:
                {{steps.inquiry.text}}

                Check their evidence in the code, then look for what contradicts the cause they give: another \
                path that produces the same symptom, a case their cause does not explain, a line they misread. \
                "confirmé" when the cause holds against what you tried; "à creuser" when something they must \
                answer remains. Your previous opinion (empty the first time):
                {{previous.challenge}}
                """,
                output: [
                    OutputField("summary", .text, "What you checked and what you think, in a few lines."),
                    OutputField("objections", .list, "Strings: what the conclusion does not explain or gets wrong. Empty when it holds."),
                ],
                timeoutSeconds: 1200,
                verdict: VerdictConfig(options: ["confirmé", "à creuser"],
                                       guidance: "\"confirmé\" when the evidence holds and nothing you found contradicts the cause.")))),
            node("report", "Rapport", x: 1040, .artifact(ArtifactConfig(template: "generic", title: "{{run.title}}"))),
        ]
        let edges = [
            WorkflowEdge(from: "start", to: "repo"),
            WorkflowEdge(from: "repo", to: "inquiry"),
            WorkflowEdge(from: "inquiry", to: "challenge"),
            WorkflowEdge(from: "challenge", to: "report"),
            WorkflowEdge(from: "challenge", to: "inquiry", when: "à creuser", retry: RetryConfig(max: 1),
                         rules: ["Answer each objection of the second opinion with evidence from the code."]),
        ]
        let workflow = Workflow(
            name: "Enquêter sur un bug",
            summary: "Remonte d'un symptôme à sa cause, la fait contester par un second avis, et écrit le plan de correction. Ne modifie rien.",
            tags: ["bug", "lecture seule"], color: "#6E56CF", nodes: nodes, edges: edges)
        return WorkflowBundle(workflow: workflow, experts: [investigator, reviewer], connectors: [])
    }
}

/// A workflow as a list (ADR-0021): its steps in the order a run reaches
/// them, with what a person wants to know before launching — who runs each
/// one, whether a session shows, where the run may go back.
public struct WorkflowOutline: Equatable, Sendable {
    public struct Step: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let type: NodeType
        /// The expert running it, when it names one.
        public let expert: String?
        /// A session of its own in the sidebar.
        public let visible: Bool
        /// It carries on another step's conversation — or its own.
        public let continues: String?
        /// Its verdict's options, best first.
        public let verdicts: [String]
        /// "↺ à revoir → Implémentation ≤2×": the ways back that start here.
        public let retries: [String]
        /// How many steps run beside it (same depth): > 1 means in parallel.
        public let parallel: Int
    }

    public let steps: [Step]

    /// Steps but the start, in topological order: a step after everything
    /// it waits on, ties in the order the workflow lists them.
    public init(_ workflow: Workflow, experts: [Expert] = [], blocks: [WorkflowBlock] = []) {
        let predecessors = WorkflowGraph.predecessors(workflow)
        var depth: [String: Int] = [:]
        func level(_ id: String, _ trail: Set<String>) -> Int {
            if let known = depth[id] { return known }
            guard !trail.contains(id) else { return 0 }
            let before = (predecessors[id] ?? []).map { level($0, trail.union([id])) }
            let value = (before.max() ?? -1) + 1
            depth[id] = value
            return value
        }
        for node in workflow.nodes { _ = level(node.id, []) }
        let order = Dictionary(workflow.nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = workflow.nodes.filter { $0.kind.type != .start }.sorted { a, b in
            (depth[a.id] ?? 0, order[a.id] ?? 0) < (depth[b.id] ?? 0, order[b.id] ?? 0)
        }
        let perDepth = Dictionary(grouping: sorted, by: { depth[$0.id] ?? 0 }).mapValues(\.count)
        steps = sorted.map { node -> Step in
            var expert: String?
            var visible = false
            var continues: String?
            switch node.kind {
            case .agent(let raw):
                let config = BlockResolver.effective(raw, blocks: blocks)
                expert = experts.first { $0.id == config.expertID }?.name
                visible = config.mode == .visible
                continues = config.continues
            case .forEach(let each):
                let config = BlockResolver.effective(each.agent, blocks: blocks)
                expert = experts.first { $0.id == config.expertID }?.name
            default:
                break
            }
            let retries = workflow.retryEdges.filter { $0.from == node.id }.map { edge -> String in
                let target = workflow.node(edge.to)?.title ?? edge.to
                return "↺ \(edge.when ?? "") → \(target) ≤\(edge.retry?.limit ?? 0)×"
            }
            return Step(id: node.id, title: node.title, type: node.kind.type, expert: expert, visible: visible,
                        continues: continues, verdicts: BlockResolver.verdictOptions(of: node, blocks: blocks),
                        retries: retries, parallel: perDepth[depth[node.id] ?? 0] ?? 1)
        }
    }

    /// "Plan → Ton accord → Implémentation → Relecture → Rapport", steps
    /// that run side by side joined by "+".
    public var oneLine: String {
        var groups: [[String]] = []
        var index = 0
        while index < steps.count {
            let count = max(1, steps[index].parallel)
            groups.append(steps[index..<min(steps.count, index + count)].map(\.title))
            index += count
        }
        return groups.map { $0.joined(separator: " + ") }.joined(separator: " → ")
    }
}
