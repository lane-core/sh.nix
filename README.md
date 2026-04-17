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

## Usage

Add `sh.nix` as a flake input, then call the builder from your shell's flake:

```nix
# ksh93-flake/flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    shnix.url = "github:yourname/sh.nix";
  };

  outputs = { self, nixpkgs, shnix }:
    let
      ksh = shnix.lib.mkPosixShellModule {
        name    = "ksh";
        package = nixpkgs.legacyPackages.x86_64-linux.ksh93;

        initFiles = {
          profile = {
            nixos       = { etcName = "profile"; };
            homeManager = { homePath = ".profile"; };
            darwin      = { etcName = "profile"; };
            when        = "login";
            envVar      = null;
          };
          rc = {
            nixos       = { etcName = "kshrc"; };
            homeManager = { homePath = ".kshrc"; };
            darwin      = { etcName = "kshrc"; };
            when        = "interactive";
            envVar      = "ENV";   # login file exports ENV=/etc/kshrc
          };
        };

        # ksh93-specific options
        extraOptions = {
          options.programs.ksh.histfile = lib.mkOption { ... };
        };

        # ksh93-specific config
        extraConfig = {
          config.programs.ksh.interactiveShellInit = lib.mkAfter ''
            HISTFILE="${config.programs.ksh.histfile}"
          '';
        };
      };
    in {
      nixosModules.ksh       = ksh.nixosModule;
      homeManagerModules.ksh = ksh.homeManagerModule;
      darwinModules.ksh      = ksh.darwinModule;
    };
}
```

End users then import the module and use it exactly like `programs.bash`:

```nix
# home.nix
{ programs.ksh = {
    enable = true;
    shellAliases = { ll = "ls -l"; };
    interactiveShellInit = ''
      set -o vi
    '';
  };
}
```

## Design

### Research basis

We traced the exact mechanisms in nixpkgs and home-manager:

| Layer | NixOS | Home-manager |
|-------|-------|--------------|
| Generic env | `environment.shellInit`, `environment.interactiveShellInit`, `environment.shellAliases` → `system.build.setEnvironment` | `home.sessionVariables`, `home.sessionSearchVariables` → `home.sessionVariablesPackage` (`hm-session-vars.sh`) |
| Bash module | Writes `/etc/profile`, `/etc/bashrc`, `/etc/bash_logout`; sources `setEnvironment`; guards with `__ETC_*_SOURCED` | Writes `~/.bash_profile`, `~/.profile`, `~/.bashrc`; sources `hm-session-vars.sh` |
| Zsh module | Writes `/etc/zshenv`, `/etc/zprofile`, `/etc/zshrc`; same env sourcing pattern | Writes `~/.zshenv`, `~/.zprofile`, `~/.zshrc`, `~/.zlogin`, `~/.zlogout` |
| Integration | Other modules write to `programs.bash.interactiveShellInit`, etc. | Other modules use `lib.hm.shell.mkBashIntegrationOption` + `programs.bash.initExtra` |

**Key insight**: the *aggregated content* (`setEnvironment`, `hm-session-vars.sh`, alias lines) is already POSIX. Only the **file wiring** and **shell-specific syntax** (shopt, setopt) vary.

### Init file abstraction

POSIX shells disagree on startup file names and semantics:

| Shell | Login | Interactive | Always | Logout |
|-------|-------|-------------|--------|--------|
| bash | `.bash_profile` | `.bashrc` | — | `.bash_logout` |
| zsh | `.zprofile` | `.zshrc` | `.zshenv` | `.zlogout` |
| ksh93 | `.profile` | `$ENV` (`.kshrc`) | — | — |
| mksh | `.profile` | `$ENV` (`.mkshrc`) | — | — |

The `initFiles` parameter lets the consumer declare exactly which files exist, when they're sourced, and which environment variable points to them. The builder then generates the correct:

- `environment.etc.<name>.text` (NixOS)
- `home.file.<path>.text` (home-manager)
- `environment.etc.<name>.text` (nix-darwin)

with appropriate idempotency guards (`__ETC_*_SOURCED`, `__HM_*_SOURCED`), `setEnvironment` / `hm-session-vars.sh` sourcing, `.local` file hooks, and `ENV` variable exports.

### Generated options

Each module exposes the same base options as `programs.bash`:

- `programs.<name>.enable`
- `programs.<name>.package`
- `programs.<name>.shellAliases`
- `programs.<name>.shellInit`
- `programs.<name>.loginShellInit`
- `programs.<name>.interactiveShellInit`
- `programs.<name>.promptInit`
- `programs.<name>.logoutExtra`

plus any `extraOptions` the consumer provides.

### Shell integration

The home-manager module adds `home.shell.enable<Name>Integration` (e.g., `home.shell.enableKshIntegration`) so other tools can toggle ksh support with the same pattern used for bash/zsh/fish.

## Project structure

```
.
├── flake.nix
├── lib/
│   ├── default.nix           # public API
│   ├── mk-posix-shell.nix    # module generator
│   └── shell-script.nix      # POSIX script helpers (exportAll, mkAliases, …)
└── example/
    └── ksh93-consumer.nix    # example usage
```

## Status

This is a design scaffold. Open questions:

1. **NixOS `/etc/profile` coordination**: if ksh93 sources `/etc/profile` on login and bash also writes `/etc/profile`, how do we avoid bash-specific code leaking into ksh93? (Current answer: we follow the zsh model — give ksh93 its own login file path when possible, or rely on POSIX-guarded sections.)
2. **nix-darwin `/etc/profile`**: darwin's bash module does not write `/etc/profile` at all. Does a generic POSIX shell on darwin need one?
3. **Completion integration**: bash has `environment.pathsToLink = [ "/share/bash-completion" ]`. How do we generalize this for arbitrary shells?

## License

MIT
