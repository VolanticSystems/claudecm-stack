# temp/

Scratch space for this project. Logs, probe scripts, intermediate output,
anything ephemeral.

Everything here except this README is gitignored.

**The rule: ephemeral is a statement about how long a file matters, not about
where it should be written.** Things stop being ephemeral without warning. When
a task finishes, anything in here that turned out to matter gets filed properly
in the project, and you say so. Do not leave the only copy of a real result in
a folder named temp.

Staged TheRegents bundles do NOT belong here: the staging tool refuses an
`-Out` inside its `-Source`, so those live outside the repository.
