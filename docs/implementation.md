# `mk-posix-shell.nix` Implementation Reference

This document codifies the specification for `mkPosixShellModule` as
implemented in `lib/mk-posix-shell.nix`. It is the canonical reference for
downstream consumers.

## Interface

```nix
shnix.lib.mkPosixShellModule {
  package = pkgs.<shell>;        # derivation whose pname names the module namespace
  etcRcPath ? package.pname + "rc";   # system-wide rc filename (no leading /etc/)
  homeRcPath ? "." + package.pname + "rc";  # user rc filename (with leading dot)
}
```

Returns:

```nix
{
  nixosModule      = { config, lib, pkgs, ... }: { ... };
  darwinModule     = { config, lib, pkgs, ... }: { ... };
  homeManagerModule = { config, lib, pkgs, ... }: { ... };
}
```

The module namespace is `programs.${pname}` where `pname = package.pname or package.name`.

## User-Facing Options

All declared under `programs.${pname}`.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | `bool` | `false` | Enable the shell and generate init files |
| `package` | `package` | `package` (input) | The shell package |
| `histFile` | `str` | `"$HOME/.${pname}_history"` | History file path |
| `histSize` | `int` | `2000` | History lines in memory |
| `shellAliases` | `attrsOf str` | `{}` | Interactive shell aliases |
| `sessionVariables` | `attrsOf (str \| int \| path)` | `{}` | Login env vars (HM only) |
| `profileExtra` | `lines` | `""` | Extra login init (HM only) |
| `initExtra` | `lines` | `""` | Extra interactive init |
| `logoutExtra` | `lines` | `""` | Logout commands (HM only; triggers logout file + trap) |

## Internal Options

Declared with `internal = true` under `programs.${pname}`. These participate in
module merging so that `mkBefore`/`mkAfter` ordering works if other modules
need to prepend or append.

| Option | Assembled From |
|--------|---------------|
| `shellInit` | `setEnvironment` bootstrap + `environment.shellInit` |
| `loginShellInit` | `environment.loginShellInit` |
| `interactiveShellInit` | `environment.interactiveShellInit` |

## NixOS Module

### Assembled options

```nix
programs.${pname}.shellInit = ''
  if [ -z "$__NIXOS_SET_ENVIRONMENT_DONE" ]; then
    . ${config.system.build.setEnvironment}
  fi
  ${config.environment.shellInit}
'';

programs.${pname}.loginShellInit = config.environment.loginShellInit;

programs.${pname}.interactiveShellInit = config.environment.interactiveShellInit;

programs.${pname}.shellAliases =
  lib.mapAttrs (name: lib.mkDefault) config.environment.shellAliases;
```

### Generated files

**`/etc/profile`** (conflicts with `programs.bash` until reconciled):

```sh
# /etc/profile: DO NOT EDIT -- this file has been generated automatically.
# This file is read for login shells.

if [ -n "$__ETC_PROFILE_SOURCED" ]; then return; fi
__ETC_PROFILE_SOURCED=1
export __ETC_PROFILE_DONE=1

${cfg.shellInit}
${cfg.loginShellInit}

if test -f /etc/profile.local; then
  . /etc/profile.local
fi

[ -r "$ENV" ] && . "$ENV"
```

**`/etc/${etcRcPath}`**:

```sh
# /etc/${etcRcPath}: DO NOT EDIT -- this file has been generated automatically.
# This file is read for interactive shells.

if [ -n "$__ETC_${PNAME}RC_SOURCED" ]; then return; fi
__ETC_${PNAME}RC_SOURCED=1

if [ -z "$__ETC_PROFILE_DONE" ]; then
  . /etc/profile
fi

HISTSIZE=${toString cfg.histSize}
HISTFILE=${cfg.histFile}

set -o noclobber
PS1="${USER}@${HOSTNAME}:${PWD}$ "

${cfg.shellAliases}

${cfg.interactiveShellInit}

if test -f /etc/${etcRcPath}.local; then
  . /etc/${etcRcPath}.local
fi

[ -r "$HOME/${homeRcPath}" ] && . "$HOME/${homeRcPath}"
```

### Other settings

- `environment.variables.ENV = lib.mkDefault "/etc/${etcRcPath}";`
- `environment.systemPackages = [ cfg.package ];`

## nix-darwin Module

### Assembled options

```nix
programs.${pname}.shellInit = ''
  if [ -z "$__NIX_DARWIN_SET_ENVIRONMENT_DONE" ]; then
    . ${config.system.build.setEnvironment}
  fi
  ${config.environment.shellInit}
'';

programs.${pname}.loginShellInit = config.environment.loginShellInit;

programs.${pname}.interactiveShellInit = config.environment.interactiveShellInit;
```

Aliases are **not** inlined — they are sourced from `system.build.setAliases` in
the generated rc file.

### Generated files

**`/etc/profile`** (shasum-protected):

```sh
# /etc/profile: DO NOT EDIT -- this file has been generated automatically.
# This file is read for login shells.

if [ -n "$__ETC_PROFILE_SOURCED" ]; then return; fi
__ETC_PROFILE_SOURCED=1
export __ETC_PROFILE_DONE=1

if [ -x /usr/libexec/path_helper ]; then
  eval `/usr/libexec/path_helper -s`
fi

${cfg.shellInit}
${cfg.loginShellInit}

if test -f /etc/profile.local; then
  . /etc/profile.local
fi

# Escape hatch for bash on darwin
if [ "${BASH-no}" != "no" ]; then
  [ -r /etc/bashrc ] && . /etc/bashrc
elif [ -r "$ENV" ]; then
  . "$ENV"
fi
```

`knownSha256Hashes` includes the stock macOS `/etc/profile` hash:
`a3fe9f414586c0d3cacbe3b6920a09d8718e503bca22e23fef882203bf765065`.

**`/etc/${etcRcPath}`** (shasum-protected, no stock hashes since file does not
exist on stock macOS):

```sh
# /etc/${etcRcPath}: DO NOT EDIT -- this file has been generated automatically.
# This file is read for interactive shells.

if [ -n "$__ETC_${PNAME}RC_SOURCED" ]; then return; fi
__ETC_${PNAME}RC_SOURCED=1

if [ -z "$__ETC_PROFILE_DONE" ]; then
  . /etc/profile
fi

HISTSIZE=${toString cfg.histSize}
HISTFILE=${cfg.histFile}

set -o noclobber
PS1="${USER}@${HOSTNAME}:${PWD}$ "

. ${config.system.build.setAliases}

${cfg.interactiveShellInit}

if test -f /etc/${etcRcPath}.local; then
  . /etc/${etcRcPath}.local
fi

[ -r "$HOME/${homeRcPath}" ] && . "$HOME/${homeRcPath}"
```

### Other settings

- `environment.variables.ENV = lib.mkDefault "/etc/${etcRcPath}";`
- `environment.variables.LANG = lib.mkDefault "C.UTF-8";`
- `environment.systemPackages = [ cfg.package ];`

## Home-Manager Module

### Generated files

**`~/.profile`** (unconditional):

```sh
# ~/.profile: DO NOT EDIT -- this file has been generated automatically.

. "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh"

${sessionVariablesStr}

${cfg.profileExtra}
```

Where `sessionVariablesStr` is:

```nix
lib.concatStringsSep "\n"
  (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg (toString v)}")
    cfg.sessionVariables)
```

**`~/.${homeRcPath}`** (e.g. `~/.kshrc`):

```sh
# ~/.${homeRcPath}: DO NOT EDIT -- this file has been generated automatically.

if [ -n "$__HOME_${PNAME}RC_SOURCED" ]; then return; fi
__HOME_${PNAME}RC_SOURCED=1

case $- in
  *i*) ;;
  *) return ;;
esac

HISTSIZE=${toString cfg.histSize}
HISTFILE=${cfg.histFile}

${aliasesStr}

${cfg.initExtra}
```

Where `aliasesStr` is:

```nix
lib.concatStringsSep "\n"
  (lib.mapAttrsToList (k: v: "alias ${k}=${lib.escapeShellArg v}")
    cfg.shellAliases)
```

**`~/.${pname}_logout`** (conditional on `cfg.logoutExtra != ""`):

```sh
# ~/.${pname}_logout: DO NOT EDIT -- this file has been generated automatically.

${cfg.logoutExtra}
```

When generated, the following is appended to `cfg.initExtra` via `mkAfter`:

```sh
trap ". $HOME/.${pname}_logout" EXIT
```

### Other settings

- `home.packages = [ cfg.package ];`

## Notes

- `PS1` uses double quotes in the generated shell script so that `${USER}`,
  `${HOSTNAME}`, and `${PWD}` expand at prompt time. The Nix `''` string uses
  `''${USER}` etc. to escape Nix interpolation.
- `HISTSIZE` and `HISTFILE` are **not** exported in the system rc files.
- On NixOS, `programs.bash` and `programs.${pname}` both set
  `environment.etc."profile"`, which is a known conflict.
- On nix-darwin, bash does **not** generate `/etc/profile`, so our generated
  file takes precedence. The bash escape hatch at the end of the file ensures
  bash still sources `/etc/bashrc`.
