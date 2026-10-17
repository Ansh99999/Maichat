# Durable working instructions

These instructions live in GitHub because development machines are temporary.
Read them when starting or resuming work on MaiChat.

## Always watch builds through completion

User instruction, 2026-10-17:

- Every time a build is running, monitor it until it reaches a terminal state.
  This includes builds triggered by a push, manual dispatch, and retries, as
  well as local builds. Do not stop after pushing or starting a build.
- Do not end the task while its build is queued or running. Keep the user
  informed during the wait.
- If a build fails, inspect the actual failed-step logs, address the cause,
  and monitor the corrected build or retry through completion too.
- For beta releases, success includes the APK upload and publication to the
  rolling beta release. Report the final outcome and link to the workflow.
- If context must be handed off, record the branch, commit, workflow run ID,
  URL, and outstanding steps in the repository handoff notes. The next session
  must resume monitoring; starting a build is not completion.
- Store lasting instructions in this repository. Local machine memory is
  supplementary and must not be the only copy.
