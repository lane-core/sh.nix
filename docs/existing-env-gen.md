# Existing Environment Generation

This document traces how NixOS and nix-darwin generate shell initialization
files for **bash** and **zsh**, as a reference for how `sh.nix` should behave
for arbitrary POSIX shells.

---

## Table of Contents

- [Common Patterns (Overview)](#common-patterns-all-shells)
- [Primer: `environment.*Init` and `system.build.setEnvironment`](#primer-environmentinit-and-systembuildsetenvironment)
  - [Accumulator options: `environment.*Init`](#1-accumulator-options-environmentinit)
  - [Standalone bootstrap: `system.build.setEnvironment`](#2-standalone-bootstrap-systembuildsetenvironment)
  - [How shell modules consume both](#3-how-shell-modules-consume-both)
  - [Default accumulated values](#4-default-accumulated-values)
- [Bash](#bash)
  - [File Layout](#file-layout)
  - [`/etc/profile`](#etcprofile)
  - [`/etc/bashrc`](#etcbashrc)
  - [`/etc/bash_logout`](#etcbash_logout)
  - [Platform differences](#bash-platform-differences-summary)
- [Zsh](#zsh)
  - [File Layout](#file-layout-1)
  - [`/etc/zshenv`](#etczshenv)
  - [`/etc/zprofile`](#etczprofile)
  - [`/etc/zshrc`](#etczshrc)
  - [Platform differences](#zsh-platform-differences-summary)
- [Home Manager](#home-manager)
  - [Shared foundation: `hm-session-vars.sh`](#shared-foundation-hm-session-varssh)
  - [Bash](#bash-1)
  - [Zsh](#zsh-1)
  - [Bash vs Zsh: key differences](#bash-vs-zsh-in-home-manager-key-differences)
  - [Shell integration mechanism (`enable*Integration`)](#shell-integration-mechanism-enableintegration)

---

## Common Patterns (All Shells)

This section is a **terse overview** of patterns shared across bash and zsh.
For the full upstream source behind each pattern, see the
[Primer](#primer-environmentinit-and-systembuildsetenvironment) below.

### 1. Guard Variables
Every generated system-wide init file starts with a guard to prevent
double-sourcing:

```sh
if [ -n "$__ETC_<FILE>_SOURCED" ] || [ -n "$NOSYS<SHELL>" ]; then return; fi
__ETC_<FILE>_SOURCED=1
```

Both bash and zsh use this exact pattern. The `NOSYS*` variable allows users
to skip system-wide initialization entirely.

### 2. Environment Bootstrap
Both shells ensure `setEnvironment` is sourced before anything else:

| Platform | Variable | File that sources it |
|----------|----------|---------------------|
| NixOS | `__NIXOS_SET_ENVIRONMENT_DONE` | Varies by shell (see below) |
| nix-darwin | `__NIX_DARWIN_SET_ENVIRONMENT_DONE` | Varies by shell (see below) |

### 3. Local File Hook
Every generated file ends with:

```sh
if test -f /etc/<file>.local; then
    . /etc/<file>.local
fi
```

### 4. `environment.interactiveShellInit`
Both shells inject `config.environment.interactiveShellInit` into their
interactive init files. This is where system-wide aliases and other
interactive setup from `environment.*` options land.

### 5. `environment.shellAliases`
Both bash and zsh modules merge `environment.shellAliases` into their own
`shellAliases` option with `lib.mkDefault` priority.

---

## Primer: `environment.*Init` and `system.build.setEnvironment`

Before diving into per-shell details, it helps to understand the two
mechanisms nixpkgs and nix-darwin use to inject content into shell init
files.

### 1. Accumulator options: `environment.*Init`

Both NixOS and nix-darwin declare the same three options.

**Source:** `nixos/modules/config/shells-environment.nix` and
`modules/environment/default.nix`

| Option | Type | Default | Purpose |
|--------|------|---------|---------|
| `environment.shellInit` | `lines` | `""` | Runs for **all** shells |
| `environment.loginShellInit` | `lines` | `""` | Runs for **login** shells |
| `environment.interactiveShellInit` | `lines` | `""` | Runs for **interactive** shells |

These are accumulator options. Any module can append to them:

```nix
# Source: nix-darwin/modules/programs/nix-index/default.nix
environment.interactiveShellInit =
  "source ${cfg.package}/etc/profile.d/command-not-found.sh";
```

**Important distinction:** `environment.shellInit` is the **system-wide**
accumulator. Each shell module also has its own `programs.<shell>.shellInit`
that wraps it. For example, the NixOS bash module sets:

```nix
# Source: nixos/modules/programs/bash/bash.nix
programs.bash.shellInit = ''
  if [ -z "$__NIXOS_SET_ENVIRONMENT_DONE" ]; then
      . ${config.system.build.setEnvironment}
  fi

  ${config.environment.shellInit}
'';
```

So `${cfg.shellInit}` inside `/etc/profile` expands to **both** the
setEnvironment bootstrap **and** any system-wide `shellInit` snippets.

**Stock/default state:** `environment.shellInit` defaults to `""` on both
platforms. No stock module sets it. `environment.loginShellInit` also
defaults to `""`.

`environment.interactiveShellInit` is the only one of the three that stock
modules commonly contribute to:
- NixOS: no stock modules set it by default
- nix-darwin: `programs.nix-index` sets it when enabled

**Platform caveat:** On nix-darwin, `environment.shellInit` is **declared**
but **never injected** into any generated shell file. Only
`environment.interactiveShellInit` is used (in `/etc/bashrc` and `/etc/zshrc`).
On NixOS, `environment.shellInit` appears in `/etc/profile` (via bash) and
`/etc/zshenv` (via zsh).

### 2. Standalone bootstrap: `system.build.setEnvironment`

This is a single shell script generated once per system configuration. It is
sourced by shell init files, gated by a platform-specific guard variable so
it only runs once per shell process.

| Platform | Output path | Guard variable |
|----------|------------|----------------|
| NixOS | `config.system.build.setEnvironment` | `__NIXOS_SET_ENVIRONMENT_DONE` |
| nix-darwin | `config.system.build.setEnvironment` | `__NIX_DARWIN_SET_ENVIRONMENT_DONE` |

**Where `setEnvironment` is sourced:**

| Shell | Platform | Sourced in | How |
|-------|----------|-----------|-----|
| Bash | NixOS | `/etc/profile` | `. ${config.system.build.setEnvironment}` |
| Bash | nix-darwin | `/etc/bashrc` | `. ${config.system.build.setEnvironment}` |
| Zsh | NixOS | `/etc/zshenv` | `. ${config.system.build.setEnvironment}` |
| Zsh | nix-darwin | `/etc/zshenv` | `. ${config.system.build.setEnvironment}` (inside `[[ -o rcs ]]`) |

The guard pattern is always:
```sh
if [ -z "$__<PLATFORM>_SET_ENVIRONMENT_DONE" ]; then
    . /nix/store/...-set-environment
fi
```

**Generation code — NixOS**

```nix
# Source: nixos/modules/config/shells-environment.nix
system.build.setEnvironment = pkgs.writeText "set-environment" ''
  # DO NOT EDIT -- this file has been generated automatically.

  # Prevent this file from being sourced by child shells.
  export __NIXOS_SET_ENVIRONMENT_DONE=1

  ${exportedEnvVars}    # ← all environment.variables + profileRelativeEnvVars

  ${cfg.extraInit}      # ← defaults to ""

  ${lib.optionalString cfg.homeBinInPath ''
    # ~/bin if it exists overrides other bin directories.
    export PATH="$HOME/bin:$PATH"
  ''}

  ${lib.optionalString cfg.localBinInPath ''
    export PATH="$HOME/.local/bin:$PATH"
  ''}
'';
```

**Generation code — nix-darwin**

```nix
# Source: modules/environment/default.nix
system.build.setEnvironment = pkgs.writeText "set-environment" ''
  # Prevent this file from being sourced by child shells.
  export __NIX_DARWIN_SET_ENVIRONMENT_DONE=1

  export PATH=${config.environment.systemPath}
  ${concatStringsSep "\n" exportVariables}

  # Extra initialisation
  ${cfg.extraInit}
'';
```

**What goes into the resulting script — nix-darwin defaults**

```nix
# Source: modules/environment/default.nix
environment.systemPath = mkMerge [
  [ (makeBinPath cfg.profiles) ]
  (mkOrder 1200 [ "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" ])
];

environment.profiles = mkMerge [
  (mkOrder 800 [ "$HOME/.nix-profile" ])
  [ "/run/current-system/sw" "/nix/var/nix/profiles/default" ]
];

environment.extraInit = ''
   export NIX_USER_PROFILE_DIR="/nix/var/nix/profiles/per-user/$USER"
   export NIX_PROFILES="${concatStringsSep " " (reverseList cfg.profiles)}"
'';

environment.variables = {
  XDG_CONFIG_DIRS = map (path: path + "/etc/xdg") cfg.profiles;
  XDG_DATA_DIRS   = map (path: path + "/share") cfg.profiles;
  EDITOR = mkDefault "nano";
  PAGER  = mkDefault "less -R";
};
```

**What goes into the resulting script — NixOS defaults**

```nix
# Source: nixos/modules/config/shells-environment.nix
environment.shellAliases = lib.mapAttrs (name: lib.mkDefault) {
  ls = "ls --color=tty";
  ll = "ls -l";
  l  = "ls -alh";
};

# environment.variables merges config.environment.sessionVariables (default {})
# and config.environment.profileRelativeEnvVars (default {})
# plus any other module contributions.
```

**`system.build.setAliases`** (nix-darwin only)

nix-darwin generates this from `environment.shellAliases`:

```nix
# Source: modules/environment/default.nix
system.build.setAliases = pkgs.writeText "set-aliases" ''
  ${concatStringsSep "\n" aliasCommands}
'';
# where aliasCommands = mapAttrsToList (n: v: ''alias ${n}=${escapeShellArg v}'') cfg.shellAliases
```

NixOS does **not** have a separate `setAliases` derivation; aliases are
injected directly into each shell's init file.

**Key differences:**
- NixOS optionally prepends `~/bin` and `~/.local/bin` to `PATH` inside
  `set-environment`; nix-darwin does not.
- nix-darwin exposes `system.build.setAliases` as a separate file; NixOS
  handles aliases per-shell.
- Both set `XDG_CONFIG_DIRS` and `XDG_DATA_DIRS` from profiles.
- Both set `NIX_USER_PROFILE_DIR` and `NIX_PROFILES`.

### 3. How shell modules consume both

Each shell module does three things:

1. **Source `setEnvironment`** once per shell process, gated by the platform
   done-flag.
2. **Inject `environment.*Init`** into the appropriate file:
   - `shellInit` → the earliest file the shell reads
   - `loginShellInit` → the login-specific file
   - `interactiveShellInit` → the interactive-specific file
3. **Merge `environment.shellAliases`** into its own `shellAliases` with
   `lib.mkDefault` priority.

### 4. Default accumulated values

| Option | nix-darwin | NixOS |
|--------|-----------|-------|
| `shellInit` | `""` (declared but **never injected**) | `""` (injected into `/etc/profile` via bash, `/etc/zshenv` via zsh) |
| `loginShellInit` | `""` (declared but **never injected**) | `""` (injected into `/etc/profile` via bash, `/etc/zprofile` via zsh) |
| `interactiveShellInit` | `""` (nix-index when enabled) | `""` (nix-index or similar when enabled) |
| `shellAliases` | None | `ls`, `ll`, `l` with `mkDefault` |
| `variables` | `XDG_CONFIG_DIRS`, `XDG_DATA_DIRS`, `EDITOR`, `PAGER` | `XDG_CONFIG_DIRS`, `XDG_DATA_DIRS`, plus `sessionVariables` |
| `extraInit` | `NIX_USER_PROFILE_DIR`, `NIX_PROFILES` | `NIX_USER_PROFILE_DIR`, `NIX_PROFILES` |
| `systemPath` | profiles + `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` | profiles + `~/bin` (if enabled) + `~/.local/bin` (if enabled) |

**Resulting script content — nix-darwin:**

```sh
export __NIX_DARWIN_SET_ENVIRONMENT_DONE=1
export PATH="/run/current-system/sw/bin:...:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export XDG_CONFIG_DIRS="/run/current-system/sw/etc/xdg"
export XDG_DATA_DIRS="/run/current-system/sw/share"
export EDITOR="nano"        # mkDefault
export PAGER="less -R"      # mkDefault
export NIX_USER_PROFILE_DIR="/nix/var/nix/profiles/per-user/$USER"
export NIX_PROFILES="/nix/var/nix/profiles/default /run/current-system/sw $HOME/.nix-profile"
```

**Resulting script content — NixOS:**

```sh
export __NIXOS_SET_ENVIRONMENT_DONE=1
export PATH="..."
export XDG_CONFIG_DIRS="..."
export XDG_DATA_DIRS="..."
# (no EDITOR/PAGER by default; sessionVariables default to {})
export NIX_USER_PROFILE_DIR="/nix/var/nix/profiles/per-user/$USER"
export NIX_PROFILES="..."
# optionally: export PATH="$HOME/bin:$PATH"
# optionally: export PATH="$HOME/.local/bin:$PATH"
```

---

## Bash

### File Layout

| File | When | Purpose |
|------|------|---------|
| `/etc/profile` | Login | Environment setup, login init, bridges to `/etc/bashrc` |
| `/etc/bashrc` | Interactive | Aliases, prompt, completion, interactive init |
| `/etc/bash_logout` | Logout | Cleanup (reset terminal title) |

### `/etc/profile`

The login file. On NixOS it is generated from scratch; on nix-darwin it is
the stock macOS file.

#### NixOS

**Source:** `nixos/modules/programs/bash/bash.nix`

```sh
if [ -n "$__ETC_PROFILE_SOURCED" ]; then return; fi
__ETC_PROFILE_SOURCED=1
export __ETC_PROFILE_DONE=1

${cfg.shellInit}      # Sources setEnvironment
${cfg.loginShellInit}

if test -f /etc/profile.local; then . /etc/profile.local; fi

if [ -n "${BASH_VERSION:-}" ]; then
    . /etc/bashrc
fi
```

**Key behaviors:**
- `/etc/profile` is **generated from scratch**; there is no stock file.
- `__ETC_PROFILE_DONE` is exported so non-login child shells can skip re-sourcing.
- `/etc/profile` explicitly sources `/etc/bashrc` at the end for all bash shells.
- `setEnvironment` is sourced here via `${cfg.shellInit}`.

#### nix-darwin

**Source:** Stock macOS file (preserved, not generated)

```sh
# System-wide .profile for sh(1)
if [ -x /usr/libexec/path_helper ]; then
    eval `/usr/libexec/path_helper -s`
fi
if [ "${BASH-no}" != "no" ]; then
    [ -r /etc/bashrc ] && . /etc/bashrc
fi
```

**Key behaviors:**
- `/etc/profile` is **preserved**; nix-darwin only appends via the stock macOS guard.
- `setEnvironment` is **not** sourced here — it is sourced in `/etc/bashrc` instead.
- The bash guard `if [ "${BASH-no}" != "no" ]` bridges to `/etc/bashrc`.

### `/etc/bashrc`

The interactive file. Generated on both platforms.

#### NixOS

**Source:** `nixos/modules/programs/bash/bash.nix`

```sh
if [ -n "$__ETC_BASHRC_SOURCED" ] || [ -n "$NOSYSBASHRC" ]; then return; fi
__ETC_BASHRC_SOURCED=1

# Bootstrap: if login file missed us, source it now
if [ -z "$__ETC_PROFILE_DONE" ]; then
    . /etc/profile
fi

# Interactive gate
if [ -n "$PS1" ]; then
    ${cfg.interactiveShellInit}
fi

if test -f /etc/bashrc.local; then . /etc/bashrc.local; fi
```

**Key behaviors:**
- Has a **fallback**: if `__ETC_PROFILE_DONE` is missing, it sources `/etc/profile`.
- This fallback re-runs `setEnvironment` (guarded, so it's a no-op).
- Interactive guard is `if [ -n "$PS1" ]`.
- `setEnvironment` was already sourced in `/etc/profile`; not sourced again here.

#### nix-darwin

**Source:** `modules/programs/bash/default.nix`

```sh
[ -r "/etc/bashrc_$TERM_PROGRAM" ] && . "/etc/bashrc_$TERM_PROGRAM"

if [ -n "$__ETC_BASHRC_SOURCED" -o -n "$NOSYSBASHRC" ]; then return; fi
__ETC_BASHRC_SOURCED=1

if [ -z "$__NIX_DARWIN_SET_ENVIRONMENT_DONE" ]; then
    . ${config.system.build.setEnvironment}
fi

# Return early if not interactive
[[ $- != *i* ]] && return

shopt -s checkwinsize
${config.system.build.setAliases.text}
${config.environment.interactiveShellInit}
${cfg.interactiveShellInit}

if test -f /etc/bash.local; then source /etc/bash.local; fi
```

**Key behaviors:**
- `setEnvironment` is sourced **here**, not in `/etc/profile`.
- Interactive guard is `[[ $- != *i* ]] && return` (not `PS1`).
- Term-specific file `bashrc_$TERM_PROGRAM` is sourced before anything else.
- Local file is `/etc/bash.local` (not `/etc/bashrc.local`).

### `/etc/bash_logout`

Only generated on NixOS.

#### NixOS

**Source:** `nixos/modules/programs/bash/bash.nix`

```sh
if [ -n "$__ETC_BASHLOGOUT_SOURCED" ] || [ -n "$NOSYSBASHLOGOUT" ]; then return; fi
__ETC_BASHLOGOUT_SOURCED=1

${cfg.logout}

if test -f /etc/bash_logout.local; then
    . /etc/bash_logout.local
fi
```

#### nix-darwin

Not generated.

### Bash: Platform Differences Summary

| Aspect | NixOS | nix-darwin |
|--------|-------|-----------|
| `/etc/profile` | Generated from scratch | Stock macOS file preserved |
| `setEnvironment` | Sourced in `/etc/profile` | Sourced in `/etc/bashrc` |
| Login→interactive bridge | End of generated `/etc/profile` | Stock `/etc/profile` guard |
| Interactive guard | `if [ -n "$PS1" ]` | `[[ $- != *i* ]] && return` |
| Term-specific file | None | `bashrc_$TERM_PROGRAM` |
| Local file suffix | `.local` | `.local` (but path is `/etc/bash.local`) |
| `/etc/bash_logout` | Generated | Not generated |

---

## Zsh

### File Layout

| File | When | Purpose |
|------|------|---------|
| `/etc/zshenv` | All | Environment, `fpath`, `setEnvironment` |
| `/etc/zprofile` | Login | Login init, aliases |
| `/etc/zshrc` | Interactive | History, completion, prompt, plugins |

Zsh has a **fixed startup order** regardless of login vs interactive:
1. `/etc/zshenv` → `~/.zshenv`
2. `/etc/zprofile` → `~/.zprofile` (login only)
3. `/etc/zshrc` → `~/.zshrc` (interactive only)
4. `/etc/zlogin` → `~/.zlogin` (login only)

### `/etc/zshenv`

The universal file (read for all shells). `setEnvironment` is sourced here
on both platforms.

#### NixOS

**Source:** `nixos/modules/programs/zsh/zsh.nix`

```sh
if [ -n "${__ETC_ZSHENV_SOURCED-}" ]; then return; fi
__ETC_ZSHENV_SOURCED=1

if [ -z "${__NIXOS_SET_ENVIRONMENT_DONE-}" ]; then
    . ${config.system.build.setEnvironment}
fi

HELPDIR="${pkgs.zsh}/share/zsh/$ZSH_VERSION/help"

for p in ${(z)NIX_PROFILES}; do
    fpath=($p/share/zsh/site-functions ... $fpath)
done

${cfge.shellInit}
${cfg.shellInit}

if test -f /etc/zshenv.local; then . /etc/zshenv.local; fi
```

**Key behaviors:**
- Sources `setEnvironment` for **all** shells (not just login).
- Sets up `fpath` for completions.
- Injects both `environment.shellInit` and `programs.zsh.shellInit`.

#### nix-darwin

**Source:** `modules/programs/zsh/default.nix`

```sh
if [ -n "${__ETC_ZSHENV_SOURCED-}" ]; then return; fi
__ETC_ZSHENV_SOURCED=1

if [[ -o rcs ]]; then
    if [ -z "${__NIX_DARWIN_SET_ENVIRONMENT_DONE-}" ]; then
        . ${config.system.build.setEnvironment}
    fi

    for p in ${(z)NIX_PROFILES}; do
        fpath=($p/share/zsh/site-functions ... $fpath)
    done

    ${cfg.shellInit}
fi

if test -f /etc/zshenv.local; then source /etc/zshenv.local; fi
```

**Key behaviors:**
- Wraps everything in `if [[ -o rcs ]]` — respects `NO_RCS`.
- Does **not** inject `environment.shellInit` (only `programs.zsh.shellInit`).

### `/etc/zprofile`

The login file. Minimal on both platforms.

#### NixOS

**Source:** `nixos/modules/programs/zsh/zsh.nix`

```sh
if [ -n "${__ETC_ZPROFILE_SOURCED-}" ]; then return; fi
__ETC_ZPROFILE_SOURCED=1

${cfge.loginShellInit}
${cfg.loginShellInit}

if test -f /etc/zprofile.local; then . /etc/zprofile.local; fi
```

**Key behaviors:**
- Minimal — just login init.
- Does **not** include aliases.

#### nix-darwin

**Source:** `modules/programs/zsh/default.nix`

```sh
if [ -n "${__ETC_ZPROFILE_SOURCED-}" ]; then return; fi
__ETC_ZPROFILE_SOURCED=1

${zshVariables}
${config.system.build.setAliases.text}
${cfg.loginShellInit}

if test -f /etc/zprofile.local; then source /etc/zprofile.local; fi
```

**Key behaviors:**
- Includes `${config.system.build.setAliases.text}` (not in NixOS zprofile).
- Has `knownSha256Hashes` for activation backup.

### `/etc/zshrc`

The interactive file.

#### NixOS

**Source:** `nixos/modules/programs/zsh/zsh.nix`

```sh
if [ -n "$__ETC_ZSHRC_SOURCED" -o -n "$NOSYSZSHRC" ]; then return; fi
__ETC_ZSHRC_SOURCED=1

setopt HIST_IGNORE_DUPS SHARE_HISTORY HIST_FCNTL_LOCK
HOST=${config.networking.fqdnOrHostName}
SAVEHIST=2000
HISTSIZE=2000
HISTFILE=$HOME/.zsh_history

. /etc/zinputrc

autoload -U compinit && compinit
autoload -U bashcompinit && bashcompinit

${cfge.interactiveShellInit}
${cfg.interactiveShellInit}

eval "$(${pkgs.coreutils}/bin/dircolors -b)"
${zshAliases}
${cfg.promptInit}

if test -f /etc/zshrc.local; then . /etc/zshrc.local; fi
```

**Key behaviors:**
- Sets history options, compinit, dircolors, aliases, prompt.
- No re-sourcing guard between `zprofile` and `zshrc` — zsh's startup order handles that.

#### nix-darwin

**Source:** `modules/programs/zsh/default.nix`

```sh
if [ -n "$__ETC_ZSHRC_SOURCED" -o -n "$NOSYSZSHRC" ]; then return; fi
__ETC_ZSHRC_SOURCED=1

SAVEHIST=2000
HISTSIZE=2000
HISTFILE=$HOME/.zsh_history
setopt HIST_IGNORE_DUPS SHARE_HISTORY HIST_FCNTL_LOCK
bindkey -e

${config.environment.interactiveShellInit}
${cfg.interactiveShellInit}
${cfg.promptInit}

autoload -U compinit && compinit
autoload -U bashcompinit && bashcompinit

# Plugin sources (autosuggestions, syntax-highlighting, fzf, etc.)

if test -f /etc/zshrc.local; then source /etc/zshrc.local; fi
```

**Key behaviors:**
- Has plugins (autosuggestions, syntax-highlighting, fzf) that NixOS handles elsewhere.
- `bindkey -e` is set (NixOS does not set this in the generated file).
- Has `knownSha256Hashes` for activation backup.

### Zsh: Platform Differences Summary

| Aspect | NixOS | nix-darwin |
|--------|-------|-----------|
| `zshenv` `rcs` guard | No | `if [[ -o rcs ]]` |
| `zshenv` `environment.shellInit` | Injected | Not injected |
| `zprofile` aliases | Not included | `${config.system.build.setAliases.text}` |
| `zshrc` plugins | None in module | autosuggestions, syntax-highlighting, fzf |
| `zshrc` keymap | Not set | `bindkey -e` |
| `knownSha256Hashes` | None | All three files |
| `setEnvironment` | `zshenv` unconditionally | `zshenv` inside `[[ -o rcs ]]` |

---

## Home Manager

Home-manager generates **user-level** init files that live in `$HOME`. These
complement the system-wide files: the shell reads system files first, then
user files. Home-manager's bash and zsh modules follow different strategies
for how they decompose the startup sequence.

### Shared Foundation: `hm-session-vars.sh`

Both bash and zsh source a common bootstrap file generated by home-manager:

```sh
. "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh"
```

This file (`hm-session-vars.sh`) is produced by `home.sessionVariablesPackage`:

```sh
# Only source this once.
if [ -n "$__HM_SESS_VARS_SOURCED" ]; then return; fi
export __HM_SESS_VARS_SOURCED=1

# Exports all home.sessionVariables
export FOO="bar"
export PATH="..."
# ...
```

It is **POSIX sh** and is sourced by every shell module. The
`__HM_SESS_VARS_SOURCED` guard prevents re-sourcing in nested shells.

### Bash

**Source:** `modules/programs/bash.nix`

Home-manager generates **four** files for bash:

| File | When | Generated by | Content |
|------|------|--------------|---------|
| `~/.bash_profile` | Login | bash module | Delegates to `~/.profile` and `~/.bashrc` |
| `~/.profile` | Login | bash module | Sources `hm-session-vars.sh`, session vars, `profileExtra` |
| `~/.bashrc` | Interactive | bash module | `bashrcExtra`, interactive gate, history, options, aliases, `initExtra` |
| `~/.bash_logout` | Logout | bash module | `logoutExtra` (only if non-empty) |

**`~/.bash_profile`:**
```sh
# include .profile if it exists
[[ -f ~/.profile ]] && . ~/.profile

# include .bashrc if it exists
[[ -f ~/.bashrc ]] && . ~/.bashrc
```

This is a **delegation layer**: bash's dedicated login file bridges to the
shared `~/.profile` (POSIX) and the dedicated `~/.bashrc` (bash-specific).

**`~/.profile`:**
```sh
. "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh"

${sessionVarsStr}       # programs.bash.sessionVariables exports
${cfg.profileExtra}     # user-defined extra login init
```

This file is **POSIX-compatible** — it contains no bash-specific syntax.
It is the shared login file that other POSIX shells (sh, ksh) can also
source.

**`~/.bashrc`:**
```sh
${cfg.bashrcExtra}

# Commands that should be applied only for interactive shells.
[[ $- == *i* ]] || return

${historyControlStr}    # HISTSIZE, HISTFILESIZE, HISTCONTROL, etc.
${shoptsStr}            # shopt settings
${aliasesStr}           # programs.bash.shellAliases
${cfg.initExtra}        # user-defined extra interactive init
```

The interactive guard `[[ $- == *i* ]] || return` is at the **top** of the
interactive section, after `bashrcExtra` (which runs even for
non-interactive shells).

**Key home-manager bash behaviors:**
- `~/.bash_profile` delegates; it contains no init logic of its own.
- `~/.profile` is POSIX and shared — other shells can source it.
- `~/.bashrc` is bash-specific and guarded for interactivity.
- `hm-session-vars.sh` is sourced **only** from `~/.profile`, not from
  `~/.bashrc`. This means non-login interactive shells (e.g., `bash` from
  an existing terminal) may not get session variables unless the parent
  shell already sourced `~/.profile`.

### Zsh

**Source:** `modules/programs/zsh/default.nix`

Home-manager generates **up to six** files for zsh, depending on which
options are set:

| File | When | Generated by | Content |
|------|------|--------------|---------|
| `~/.zshenv` | All | zsh module | Sources `hm-session-vars.sh`, session vars |
| `~/.zprofile` | Login | zsh module | `profileExtra` (only if non-empty) |
| `~/.zshrc` | Interactive | zsh module | `initContent` (ordered fragments) |
| `~/.zlogin` | Login | zsh module | `loginExtra` (only if non-empty) |
| `~/.zlogout` | Logout | zsh module | `logoutExtra` (only if non-empty) |
| `${dotDir}/.zshenv` | All | zsh module | ZDOTDIR redirect (when `dotDir` is set) |

**`~/.zshenv`:**
```sh
# Environment variables
. "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh"

# Only source this once
if [[ -z "$__HM_ZSH_SESS_VARS_SOURCED" ]]; then
  export __HM_ZSH_SESS_VARS_SOURCED=1
  ${envVarsStr}         # programs.zsh.sessionVariables exports
fi
```

**`~/.zshrc`:**
The `.zshrc` is built from `cfg.initContent`, which is an ordered
`types.lines` value. Fragments are added with specific `lib.mkOrder`
priorities:

| Order | Content |
|-------|---------|
| 500 (`mkBefore`) | `typeset -U path cdpath fpath manpath` |
| 510 | `cdpath` additions, `fpath` from `NIX_PROFILES`, `HELPDIR` |
| 530 | `bindkey` (default keymap) |
| 540 | `localVariables` |
| 570 | `compinit` (unless Oh-My-Zsh/Prezto) |
| 700 | autosuggestions plugin |
| 950 | `setOptions` |
| 1100 | aliases, global aliases |
| 1150 | `dirHashes` |
| 1200 | syntax highlighting plugin |
| 1000 (default) | General `initContent` |
| 1500 (`mkAfter`) | Last-run configuration |

**Key home-manager zsh behaviors:**
- `~/.zshenv` sources `hm-session-vars.sh` for **all** shells, not just
  login shells. This is because zsh reads `zshenv` universally.
- `~/.zprofile` is minimal and only contains `profileExtra` if set.
- `~/.zshrc` uses an **ordered content model** (`initContent` with
  `lib.mkOrder`) instead of the bash model of string concatenation.
- When `dotDir` is set, `~/.zshenv` becomes a one-line redirect to
  `${ZDOTDIR}/.zshenv`, which then sources `hm-session-vars.sh`.
- No dedicated login→interactive bridge file — zsh's startup order
  (`zshenv` → `zprofile` → `zshrc`) handles this naturally.

### Bash vs Zsh in Home Manager: Key Differences

| Aspect | Bash | Zsh |
|--------|------|-----|
| `hm-session-vars.sh` sourced in | `~/.profile` only | `~/.zshenv` (all shells) |
| Login→interactive bridge | `~/.bash_profile` → `~/.profile` + `~/.bashrc` | Fixed startup order (`zprofile` → `zshrc`) |
| Shared POSIX login file | `~/.profile` | `~/.zprofile` (zsh-specific, not shared) |
| Interactive file model | String concatenation | Ordered `initContent` with `mkOrder` |
| Interactive guard | `[[ $- == *i* ]] \|\| return` | No guard needed (`zshrc` is inherently interactive-only) |
| Session variables guard | `__HM_SESS_VARS_SOURCED` | `__HM_ZSH_SESS_VARS_SOURCED` |
| File count | Always 3–4 files | 1–6 files depending on options |

### Shell Integration Mechanism (`enable*Integration`)

Many home-manager program modules (e.g., `eza`, `atuin`, `television`,
`wezterm`) support per-shell integration toggles. This is a standardized
pattern that lets users selectively enable or disable a tool's shell hooks
(aliases, keybindings, completions, init scripts) per shell.

#### Global vs Per-Program Options

**Global options** (`modules/misc/shell.nix`):

```nix
options.home.shell = {
  enableShellIntegration = lib.mkOption {
    type = lib.types.bool;
    default = true;
  };

  enableBashIntegration = lib.hm.shell.mkBashIntegrationOption { inherit config; };
  enableZshIntegration  = lib.hm.shell.mkZshIntegrationOption  { inherit config; };
  enableFishIntegration = lib.hm.shell.mkFishIntegrationOption { inherit config; };
  # ...
};
```

**Per-program options** (example from `programs/eza.nix`):

```nix
options.programs.eza = {
  enableBashIntegration = lib.hm.shell.mkBashIntegrationOption { inherit config; };
  enableZshIntegration  = lib.hm.shell.mkZshIntegrationOption  { inherit config; };
  # ...
};
```

**The helper** (`modules/lib/shell.nix`):

```nix
mkShellIntegrationOption = name: { config, baseName ? name, ... }:
  let attrName = "enable${baseName}Integration";
  in lib.mkOption {
    default = config.home.shell.${attrName};  # ← inherits from global
    defaultText = lib.literalMD "[](#opt-home.shell.${attrName})";
    type = lib.types.bool;
  };
```

**Default behavior:**
- `home.shell.enableShellIntegration = true` (global default)
- `home.shell.enableBashIntegration = true` (inherits global)
- `programs.eza.enableBashIntegration = true` (inherits `home.shell`)

So by default, enabling a program enables its hooks for **all supported
shells**. To disable globally:

```nix
home.shell.enableShellIntegration = false;
```

To disable for just one shell:

```nix
home.shell.enableBashIntegration = false;     # global bash override
# or
programs.eza.enableBashIntegration = false;   # per-program bash override
```

#### How Program Modules Consume the Flags

Each program module conditionally injects shell-specific config:

```nix
# From programs/eza.nix
config = lib.mkIf cfg.enable {
  programs.bash.shellAliases = optionalAttrs cfg.enableBashIntegration {
    ls = "eza";
    ll = "eza -l";
    # ...
  };

  programs.zsh.shellAliases = optionalAttrs cfg.enableZshIntegration {
    ls = "eza";
    ll = "eza -l";
    # ...
  };
};
```

For tools that need init scripts (not just aliases):

```nix
# Source: modules/programs/atuin.nix
programs.bash.initExtra = mkIf cfg.enableBashIntegration ''
  if [[ :$SHELLOPTS: =~ :(vi|emacs): ]]; then
    source "${pkgs.bash-preexec}/share/bash/bash-preexec.sh"
    eval "$(${lib.getExe cfg.package} init bash ${flagsStr})"
  fi
'';

programs.zsh.initContent = mkIf cfg.enableZshIntegration ''
  if [[ $options[zle] = on ]]; then
    eval "$(${lib.getExe cfg.package} init zsh ${flagsStr})"
  fi
'';
```

**Key observations:**
- The integration flag controls **which shell's init file** gets the hook.
- Aliases go into `programs.<shell>.shellAliases` (merged by the shell module).
- Init scripts go into `programs.<shell>.initExtra` / `initContent` / `interactiveShellInit`.
- The shell module (bash or zsh) is responsible for merging these fragments
  into the final generated file.
