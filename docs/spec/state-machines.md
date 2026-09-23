# State machines

Machine-readable definitions are stored in `spec/state-machines/` and validated for referential integrity and reachability.

## Kernel lifecycle

States:

- `stopped`: no owned live kernel;
- `starting`: process or attachment is being established;
- `idle`: ready for requests;
- `busy`: at least one execution is active;
- `interrupting`: interrupt was requested and acknowledgement is pending;
- `restarting`: old session is being replaced;
- `shutting_down`: graceful or forced shutdown is in progress;
- `dead`: kernel exited or communication became unrecoverable;
- `error`: lifecycle operation failed without a usable kernel.

Important rules:

- execution can start only from `idle` or join the queue while `busy`;
- interrupt does not imply successful cancellation until the kernel returns to `idle`;
- restart invalidates queued and running execution IDs from the old generation;
- unexpected process exit leads to `dead`, never directly to `stopped`;
- recovery from `dead` creates a new kernel generation.

## Execution lifecycle

States:

- `created`;
- `queued`;
- `sent`;
- `running`;
- `waiting_input`;
- `completed`;
- `failed`;
- `cancelled`;
- `stale`.

Rules:

- terminal states are `completed`, `failed`, `cancelled`, and `stale`;
- editing source does not terminate kernel work, but makes its result stale relative to the visible revision;
- every output event carries execution ID, cell ID, and source revision;
- batch execution uses an immutable ordered list of cell IDs;
- `stop_on_error` prevents unsent later items from leaving `queued`;
- cancellation of a sent request is best-effort and usually requires kernel interrupt.

## Renderer lifecycle

States:

- `stopped`;
- `starting`;
- `ready`;
- `rendering`;
- `interactive`;
- `suspended`;
- `disposing`;
- `crashed`;
- `blocked`.

`blocked` means trust policy refused active rendering. Static safe fallback may still be displayed.

## Trust lifecycle

States:

- `unknown`;
- `untrusted`;
- `trusted_static`;
- `trusted_interactive`;
- `revoked`.

Persisted trust is keyed to notebook content identity. A change that affects executable or active content invalidates the previous interactive trust decision and returns to `unknown` or `untrusted` according to policy. Output received from an explicitly invoked local kernel may enter `trusted_interactive` through an in-memory, cell-revision-scoped grant; editing that cell invalidates the grant, and `revoked` takes precedence.
