---
status: superseded by ADR-0007
---

# Require integrated surfaces to attach to TACO sessions

TACO considers a terminal or agent UI integrated only when it is an Attached
Surface of a TACO-owned Session. TACO's native terminal and external applications
may present a Session through different surfaces at different times; merely
launching, tiling, or focusing an external window creates a Companion Window, not
an integrated panel. This accepts the cost of a session bridge so TACO does not
become a window manager that only appears integrated.
