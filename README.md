# forge-public-info

Public assets for [@aion0/forge](https://www.npmjs.com/package/@aion0/forge) — installer, docs, marketing material.

## One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/aiwatching/forge-public-info/main/install-deps.sh | bash
```

This detects your OS, installs missing system dependencies (`tmux`, `git`, `claude` CLI, optional `jq`/`glab`/`gh`) via Homebrew or apt/dnf/pacman/zypper, then runs `npm install -g @aion0/forge`.

Non-interactive variant:

```bash
curl -fsSL https://raw.githubusercontent.com/aiwatching/forge-public-info/main/install-deps.sh | bash -s -- --yes
```

Skip optional CLIs:

```bash
curl -fsSL https://raw.githubusercontent.com/aiwatching/forge-public-info/main/install-deps.sh | bash -s -- --skip-optional
```

## After install

```bash
forge server start          # background, logs to ~/.forge/data/forge.log
open http://localhost:8403  # set admin password on first visit
```

See the team onboarding deck for the wizard flow.
