# Federate external project environments without taking them over

TACO supports two structured integration modes: an Attached Surface presents a
Session owned by `tacod`, while a Federated Panel keeps its provider's internal
sessions, PTYs, agents, and layout behind a structured project-level adapter.
Launch, tiling, and focus alone remain a Companion Window. cmux starts as a
Federated Panel associated with a TACO Checkout: TACO may create, open, focus, and
observe coarse activity or attention through public interfaces, but does not yet
take over cmux panes or persist their block streams.
