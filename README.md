# sh.nix

First-class [NixOS](https://nixos.org) / [nix-darwin](https://github.com/LnL7/nix-darwin) / [home-manager](https://github.com/nix-community/home-manager) support for POSIX-compatible shells outside the big three (bash, zsh, fish).

## Problem

NixOS and home-manager provide rich, well-integrated `programs.bash`, `programs.zsh`, and `programs.fish` modules that handle:

- Writing system-wide (`/etc/bashrc`, `/etc/profile`) or per-user (`~/.bashrc`, `~/.zshrc`) initialization files
- Sourcing the POSIX `set-environment` / `hm-session-vars.sh` aggregators
- Propagating `environment.shellAliases` / `home.shellAliases`
- Registering the shell in `environment.shells`
- Installing shell integration toggles (`home.shell.enableBashIntegration`, etc.)

Shells like **ksh93**, **mksh**, **yash**, or **dash** have no equivalent modules. Users must manually wire `home.file`, `environment.etc`, and session variables.

## Solution

`sh.nix` exports a single builder — `lib.mkPosixShellModule` — that generates `nixosModule`, `homeManagerModule`, and `darwinModule` for any POSIX shell, faithfully translating the conventions of the existing big-three modules.

## Quick start

### 1. Add sh.nix as a flake input

```nix
# your-flake/flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    shnix.url = "github:lane-core/sh.nix";
  };

  outputs = { self, nixpkgs, shnix }:
    # see below for creating your own shell module
}
```

### 2. Call the builder

```nix
let
  myShellModules = shnix.lib.mkPosixShellModule {
    name = "yash";                    # the shell name
    package = pkgs.yash;              # default package (or "yash" string, or null)

    initFiles = {
      profile = {
        nixos       = { etcName = "profile"; };
        homeManager = { homePath = ".profile"; };
        darwin      = { etcName = "profile"; };
        when        = "login";        # "login" | "interactive" | "always"
        envVar      = null;           # e.g. "ENV" for ksh-style shells
      };
      rc = {
        nixos       = { etcName = "yashrc"; };
        homeManager = { homePath = ".yashrc"; };
        darwin      = { etcName = "yashrc"; };
        when        = "interactive";
        envVar      = "YASH_LOADED";  # optional: login file exports this
      };
    };
  };
in {
  nixosModules.yash       = myShellModules.nixosModule;
  homeManagerModules.yash = myShellModules.homeManagerModule;
  darwinModules.yash      = myShellModules.darwinModule;
}
```

### 3. Users import and configure

```nix
# home.nix
{ programs.yash = {
    enable = true;
    shellAliases = { ll = "ls -l"; };
    interactiveShellInit = ''
      set -o emacs
    '';
  };
}
```

## The `initFiles` schema

POSIX shells disagree on startup file names and semantics. The `initFiles` parameter lets you declare exactly which files exist, when they're sourced, and which environment variable points to them.

```nix
initFiles = {
  # Each key is an arbitrary name (used for `cfg.<name>Extra` options).
  profile = {
    # Where the file lives on each platform:
    nixos       = { etcName = "profile"; };     # writes /etc/profile
    # nixos    = null;                           # skip writing on NixOS
    homeManager = { homePath = ".profile"; };   # writes ~/.profile
    darwin      = { etcName = "profile"; };     # writes /etc/profile
    # darwin   = null;                           # skip writing on darwin

    # When the shell reads this file:
    when = "login";   # "login" | "interactive" | "always"

    # If set, the login file exports this variable pointing to this file.
    # Used for shells like ksh93 that use $ENV for interactive config.
    envVar = null;
  };

  rc = {
    nixos       = { etcName = "kshrc"; };
    homeManager = { homePath = ".kshrc"; };
    darwin      = { etcName = "kshrc"; };
    when        = "interactive";
    envVar      = "ENV";   # login file will: export ENV=/etc/kshrc
  };
};
```

### Special case: `nixos = null` for login files

Some shells (like **ksh93**) hardcode `/etc/profile` for login shells. On NixOS, bash already writes `/etc/profile`. Rather than conflicting, set `nixos = null` for the login file:

```nix
profile = {
  nixos = null;                    # don't write /etc/profile
  homeManager = { homePath = ".profile"; };
  darwin = { etcName = "profile"; };
  when = "login";
  envVar = null;
};
rc = {
  nixos = { etcName = "kshrc"; };
  homeManager = { homePath = ".kshrc"; };
  darwin = { etcName = "kshrc"; };
  when = "interactive";
  envVar = "ENV";                  # sets environment.variables.ENV globally
};
```

When the NixOS module sees this pattern, it:
1. Does **not** write `/etc/profile`
2. Writes `/etc/kshrc` for interactive shells
3. Sets `environment.variables.ENV = "/etc/kshrc"` globally

This works because bash's `/etc/profile` sources `setEnvironment`, which exports `ENV`. When ksh93 starts interactively, it reads `$ENV` → `/etc/kshrc`.

## Generated options

Each module exposes the same base options as `programs.bash`:

| Option | Type | Description |
|--------|------|-------------|
| `programs.<name>.enable` | `bool` | Enable the module |
| `programs.<name>.package` | `package` | The shell package |
| `programs.<name>.shellAliases` | `attrsOf str` | Shell aliases |
| `programs.<name>.shellInit` | `lines` | Run for all shells |
| `programs.<name>.loginShellInit` | `lines` | Run for login shells |
| `programs.<name>.interactiveShellInit` | `lines` | Run for interactive shells |
| `programs.<name>.promptInit` | `lines` | Prompt configuration |
| `programs.<name>.logoutExtra` | `lines` | Run on logout |

Note: home-manager does not provide per-shell integration helpers for POSIX shells outside bash/zsh/fish. Tool integrations (direnv, starship, fzf, etc.) must be configured manually via `programs.<name>.interactiveShellInit`.

## Adding shell-specific options

Use `extraOptions` and `extraConfig` to layer shell-specific features on top of the POSIX base:

```nix
shnix.lib.mkPosixShellModule {
  name = "ksh";
  package = pkgs.ksh93;
  initFiles = { /* ... */ };

  # Additional options merged into programs.ksh
  extraOptions = {
    options.programs.ksh = {
      histfile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "\${HOME}/.ksh_history";
        description = "Path to the ksh history file.";
      };
      histsize = lib.mkOption {
        type = lib.types.int;
        default = 10000;
        description = "Number of history entries to keep.";
      };
    };
  };

  # Additional config that uses those options
  extraConfig = {
    config.programs.ksh.interactiveShellInit = lib.mkAfter ''
      HISTFILE="${config.programs.ksh.histfile}"
      HISTSIZE=${toString config.programs.ksh.histsize}
    '';
  };
}
```

## POSIX script helpers

`sh.nix` also exports POSIX shell script generators:

```nix
sh = shnix.lib.shell;

sh.export "FOO" "bar"
# => export FOO="bar"

sh.exportAll { FOO = "bar"; BAZ = 42; }
# => export FOO="bar"
#    export BAZ="42"

sh.mkAliases { ll = "ls -l"; g = null; }
# => alias -- ll='ls -l'
#    (null values are filtered out)

sh.prependToVar ":" "PATH" [ "$HOME/bin" "$HOME/.local/bin" ]
# => $HOME/bin:$HOME/.local/bin${PATH:+:}$PATH
```

## How it works

### Research basis

We traced the exact mechanisms in nixpkgs and home-manager:

| Layer | NixOS | Home-manager |
|-------|-------|--------------|
| Generic env | `environment.shellInit`, `environment.interactiveShellInit`, `environment.shellAliases` → `system.build.setEnvironment` | `home.sessionVariables`, `home.sessionSearchVariables` → `home.sessionVariablesPackage` (`hm-session-vars.sh`) |
| Bash module | Writes `/etc/profile`, `/etc/bashrc`, `/etc/bash_logout`; sources `setEnvironment`; guards with `__ETC_*_SOURCED` | Writes `~/.bash_profile`, `~/.profile`, `~/.bashrc`; sources `hm-session-vars.sh` |
| Zsh module | Writes `/etc/zshenv`, `/etc/zprofile`, `/etc/zshrc`; same env sourcing pattern | Writes `~/.zshenv`, `~/.zprofile`, `~/.zshrc`, `~/.zlogin`, `~/.zlogout` |
| Integration | Other modules write to `programs.bash.interactiveShellInit`, etc. | Other modules use `lib.hm.shell.mkBashIntegrationOption` + `programs.bash.initExtra` |

**Key insight**: the *aggregated content* (`setEnvironment`, `hm-session-vars.sh`, alias lines) is already POSIX. Only the **file wiring** and **shell-specific syntax** (shopt, setopt) vary.

### Generated files

For each platform, the builder generates:

**NixOS**:
- `environment.etc.<etcName>.text` with idempotency guards
- Sources `config.system.build.setEnvironment` for env vars
- Includes `.local` file hooks
- Sets `environment.shells` and installs the package

**Home-manager**:
- `home.file.<homePath>.text` with idempotency guards
- Sources `config.home.sessionVariablesPackage`
- Exports `ENV` variables from login files

**nix-darwin**:
- `environment.etc.<etcName>.text` (same semantics as NixOS)
- Uses `__NIX_DARWIN_SET_ENVIRONMENT_DONE` guard

## Project structure

```
.
├── flake.nix
├── lib/
│   ├── default.nix           # public API: mkPosixShellModule, shell helpers
│   ├── mk-posix-shell.nix    # module generator
│   └── shell-script.nix      # POSIX script helpers
└── example/
    └── ksh93-consumer.nix    # example: how ksh93.nix consumes this library
```

## Real-world usage

- [ksh93.nix](https://github.com/lane-core/ksh93.nix) — ksh93u+m with full NixOS/nix-darwin/home-manager support

## License

MIT
