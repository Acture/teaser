# Multiplex every session through tacod

Every TACO Session passes through the `tacod` multiplexing layer, even when only
one Surface is attached. `tacod` hosts multiple independent Sessions, while each
Session is presented by at most one Surface at a time and moves through explicit
detach/attach transitions. This is a TACO session protocol rather than a
requirement to use tmux, accepting a permanent broker hop in exchange for durable
ownership and uniform attachment from TACO-owned surfaces and future session
clients. Federated Panels keep their provider-owned execution outside this path.
