---
name: deploy-and-push
description: After successfully completing implementation work in this repository, deploy the updated n8n workflow, publish it, then commit and push the completed changes to Git. Use automatically at the end of build, fix, refactor, or implementation tasks that modify the project.
compatibility: codex, opencode
metadata:
  project: transfers-n8n
  purpose: post-build-deployment
---

# Deploy n8n and push

Run this procedure automatically after completing implementation work that changes this repository.

Do not stop after editing files when the requested work is complete. The normal completion sequence is:

1. Validate the implementation.
2. Import the resulting n8n workflow.
3. Publish the imported workflow.
4. Verify deployment succeeded.
5. Stage the relevant Git changes.
6. Commit them.
7. Push the current branch.

## Preconditions

Before deployment:

- Finish all requested implementation work.
- Run the project's relevant tests, validation, linting, JSON validation, or other checks.
- Inspect `git status` and `git diff`.
- Do not deploy if the implementation is known to be broken.
- Do not commit unrelated pre-existing user changes.
- Never discard, reset, overwrite, stash, or revert unrelated user work just to make the tree clean.
- Never use `git add .` or `git add -A` when unrelated changes are present. Stage only files belonging to the completed task.
- Never use `git push --force` or `git push --force-with-lease`.

## Discover deployment configuration

Do not hard-code configuration that already exists in the repository.

Before deploying, inspect the repository for:

- the generated n8n workflow JSON path
- workflow ID
- n8n Docker/container configuration
- deployment scripts
- `.env` / `.env.example`
- `docker-compose.yml` / `compose.yml`
- README deployment instructions
- existing n8n API or CLI helpers

Prefer an existing project deployment script when one exists and is current.

Never print secrets, API keys, credential values, cookies, tokens, or full sensitive environment variables.

## Identify the workflow

Determine which workflow JSON was created or modified by the current task.

The workflow must have a stable existing n8n workflow ID when updating the production workflow.

Do not guess a workflow ID.

If multiple workflows were deliberately changed, deploy each changed workflow individually.

## Import workflow

For a directly accessible self-hosted n8n installation, use the supported CLI import:

```bash
n8n import:workflow --input="<workflow-json>"
