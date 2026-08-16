# SessionManager dans un target LoomSessions, pas dans LoomCore

Le §6.1 du cahier des charges place `SessionManager` dans LoomCore, mais il orchestre des `SessionRuntime` qui vivent dans LoomTerminal — et Core ne peut pas dépendre de Terminal sans inverser le sens des dépendances. Alternatives : un protocole de runtime dans Core (rejeté : un seul adapter = seam hypothétique, discipline ADR-0008) ou un target d'orchestration au-dessus des deux. Décision : `LoomSessions` (dépend de Core, Terminal, Agents) héberge `SessionManager` ; Core garde ce qui est pur (états, réducteur, identités).
