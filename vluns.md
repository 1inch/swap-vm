Issue 1: Program Counter Jump Limit Not Enforced
Title: [P3] Enforce program size limit for jump instructions (65,535 bytes)
Labels: priority: P3, type: enhancement, area: VM/execution
Body:
Description
The VM execution engine documents a 65,535 byte program size limit due to uint16 jump offsets in Controls.sol, but this limit is not enforced at deployment or runtime.
Locations
src/instructions/Controls.sol:76-78 — Documents the limitation
src/libs/VM.sol:111-114 — Documents the limitation in runLoop()
Current Behavior
Programs larger than 65,535 bytes can be deployed and executed. Jump instructions (_jump, _jumpIfDirection, _jumpIfTokenIn, _jumpIfTokenOut) will silently wrap or fail when targeting offsets ≥ 65,536.
Expected Behavior
Add validation to reject programs exceeding 65,535 bytes:
// In SwapVM constructor or during order validation
require(program.length <= 65535, "Program exceeds jump limit");
Or enforce at runtime in runLoop() before parsing opcodes.
Impact
 Makers may deploy strategies that appear to work but fail at specific jump targets
Silent failures difficult to debug
No on-chain protection against oversized bytecode
Recommendation
Add explicit require(program.length <= type(uint16).max, "ProgramTooLarge") in ContextLib.runLoop() before the execution loop.
---
Issue 2: Missing Events for Failed Operations & Inconsistent Error Handling
Title: [P3] Add failure events and standardize on custom errors
Labels: priority: P3, type: enhancement, area: observability, area: error-handling
Body:
Description
The contract emits no events for validation failures, reverts, or hook failures — making monitoring, debugging, and incident response difficult. Error handling mixes custom errors and string require messages.
Current Issues
1. No failure events — Silent reverts on:
Signature verification failure (BadSignature — custom error exists but no event)
 Deadline expiry (TakerTraitsDeadlineExpired)
Balance checks (TakerTokenBalanceIsZero, etc.)
 Invalidator checks (InvalidatorsBitAlreadySet, etc.)
 Hook/callback reverts
 quote() validation failures
2. Inconsistent error style:
// Custom errors (good) - SwapVM.sol
error BadSignature(address maker, bytes32 orderHash, bytes signature);
// String requires (inconsistent) - Controls.sol
require(balance > 0, "TakerTokenBalanceIsZero");
Recommendations
A. Add failure events:
event SwapFailed(
    bytes32 indexed orderHash,
    address indexed taker,
    string reason  // Or custom error indexed params
);
event HookFailed(
    bytes32 indexed orderHash,
    address indexed hookTarget,
    string hookType,  // "preTransferIn" | "postTransferOut" | etc.
    string reason
);
event QuoteFailed(
    bytes32 indexed orderHash,
    address indexed taker,
    string reason
);
To create these issues:m errorsInconsistent developer experienceplace string require messages with custom errors matching the existing pattern in SwapVM.s0�, Controls�:, Invalida���:&O��, Fee.sol, etc.).
Impact
 Off-chain monitoring cannot detect attack attempts or systematic failures
Debugging production issues requires transaction tracing instead of event logs
Inconsistent developer experience
