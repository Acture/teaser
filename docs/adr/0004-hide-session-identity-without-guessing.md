# Hide session identity without guessing

Every Attachment targets an exact Session identity, but normal user workflows do
not expose or require that identity. TACO passes it when opening an Attached
Surface, while independently opened clients must select or create a Session rather
than infer one solely from the Checkout path. This preserves zero-ID ergonomics
without making routing ambiguous when a Checkout has concurrent Sessions.
