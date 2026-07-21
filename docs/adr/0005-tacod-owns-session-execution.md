# Let tacod own session execution

The long-lived `tacod` runtime owns each Session's canonical process, PTY, block
state, and lifetime; user interfaces presenting a TACO Session attach as surfaces.
External tools may instead participate as Federated Panels while retaining their
own execution. This supersedes the previous assumption that a direct PTY dies with
the TACO GUI. It accepts a bridge and an additional byte-transfer hop so TACO
Sessions can survive UI exit; bridge latency therefore becomes a mandatory
feasibility gate.
