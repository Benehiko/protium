# AI policy

AI use is encouraged. protium is vibe coded: the code here was written with
coding agents. It is also tested on a real Mac mini M4 by the maintainer, and
exhaustive QA happens before anything is merged. Hold your change to the same
bar. An agent can write the code, but you are responsible for checking that it
works.

## What a pull request needs

* **One topic.** A PR fixes one bug or adds one feature. If you find something
  else along the way, open a separate PR for it.
* **A clear reason.** You don't need to open an issue first, but the PR body
  must explain what is broken or what feature is needed, and why.
* **How you tested it.** List the steps you took, both:
  * **Manual:** what you ran on a real Mac and what you saw. For example, the
    commands, the games or prefixes involved, and the results.
  * **Automated:** the tests you ran (`zig build test`) and any tests you
    added.
* **What wrote it.** Name the model (for example, Claude Opus 4.5) and the
  coding agent (for example, Claude Code) you used.

## PR body template

```markdown
## What and why

<What is broken, or what feature is needed, and why.>

## Testing

Manual:
1. ...

Automated:
- `zig build test`
- ...

## AI

Model: <model name and version>
Coding agent: <agent name>
```

PRs that are missing any of these, or that cover more than one topic, will be
asked to change before review.
