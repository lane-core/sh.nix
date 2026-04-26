# Generates NixOS, nix-darwin, and home-manager modules for a POSIX-compatible
# shell, following the established conventions of programs.bash, programs.zsh,
# and programs.fish.
#
# Usage:
#   mkPosixShellModule {
#     package = pkgs.ksh;
#     etcRcPath = "kshrc";      # optional, default: package.pname + "rc"
#     homeRcPath = ".kshrc";    # optional, default: "." + package.pname + "rc"
#   }
# => { nixosModule, darwinModule, homeManagerModule }

{
  package,
  etcRcPath ? package.pname + "rc",
  homeRcPath ? "." + package.pname + "rc",
}:

let
  pname = package.pname or package.name;
in

{
  nixosModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      PNAME = lib.toUpper pname;
      cfg = config.programs.${pname};

      aliasesStr = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (k: v: "alias ${k}=${lib.escapeShellArg v}") cfg.shellAliases
      );
    in
    {
      options.programs.${pname} = {
        enable = lib.mkEnableOption "${pname} shell";

        package = lib.mkOption {
          type = lib.types.package;
          default = package;
          defaultText = lib.literalExpression "pkgs.${pname}";
          description = "The ${pname} package to use.";
        };

        histFile = lib.mkOption {
          type = lib.types.str;
          default = "$HOME/.${pname}_history";
          description = "Path to the history file. Evaluated at shell runtime.";
        };

        histSize = lib.mkOption {
          type = lib.types.int;
          default = 2000;
          description = "Number of history lines to keep in memory.";
        };

        shellAliases = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "Aliases to define in interactive shells.";
        };

        initExtra = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Additional commands for interactive shell init.";
        };

        # internally assembled — do not set manually
        shellInit = lib.mkOption {
          type = lib.types.lines;
          default = "";
          internal = true;
          visible = false;
        };

        loginShellInit = lib.mkOption {
          type = lib.types.lines;
          default = "";
          internal = true;
          visible = false;
        };

        interactiveShellInit = lib.mkOption {
          type = lib.types.lines;
          default = "";
          internal = true;
          visible = false;
        };
      };

      config = lib.mkIf cfg.enable {
        environment.systemPackages = [ cfg.package ];

        environment.variables.ENV = lib.mkDefault "/etc/${etcRcPath}";

        programs.${pname}.shellInit = ''
          if [ -z "$__NIXOS_SET_ENVIRONMENT_DONE" ]; then
            . ${config.system.build.setEnvironment}
          fi
          ${config.environment.shellInit}
        '';

        programs.${pname}.loginShellInit = config.environment.loginShellInit;

        programs.${pname}.interactiveShellInit = config.environment.interactiveShellInit;

        programs.${pname}.shellAliases = lib.mapAttrs (name: lib.mkDefault) config.environment.shellAliases;

        environment.etc.${etcRcPath}.text = ''
          # /etc/${etcRcPath}: DO NOT EDIT -- this file has been generated automatically.
          # This file is read for interactive shells.

          # Only execute this file once per shell.
          if [ -n "$__ETC_${PNAME}RC_SOURCED" ]; then return; fi
          __ETC_${PNAME}RC_SOURCED=1

          # If /etc/profile was not loaded in a parent process, source it.
          if [ -z "$__ETC_PROFILE_DONE" ]; then
            . /etc/profile
          fi

          # Setup command line history.
          HISTSIZE=${toString cfg.histSize}
          HISTFILE=${cfg.histFile}

          # Safe defaults.
          set -o noclobber
          PS1="''${USER}@''${HOSTNAME}:''${PWD}$ "

          ${aliasesStr}

          ${cfg.interactiveShellInit}

          # Read system-wide modifications.
          if test -f /etc/${etcRcPath}.local; then
            . /etc/${etcRcPath}.local
          fi

          [ -r "$HOME/${homeRcPath}" ] && . "$HOME/${homeRcPath}"
        '';

        environment.etc."profile".text = ''
          # /etc/profile: DO NOT EDIT -- this file has been generated automatically.
          # This file is read for login shells.

          # Only execute this file once per shell.
          if [ -n "$__ETC_PROFILE_SOURCED" ]; then return; fi
          __ETC_PROFILE_SOURCED=1

          # Prevent this file from being sourced by interactive non-login child shells.
          export __ETC_PROFILE_DONE=1

          ${cfg.shellInit}

          ${cfg.loginShellInit}

          # Read system-wide modifications.
          if test -f /etc/profile.local; then
            . /etc/profile.local
          fi

          [ -r "$ENV" ] && . "$ENV"
        '';
      };
    };

  darwinModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      PNAME = lib.toUpper pname;
      cfg = config.programs.${pname};
    in
    {
      options.programs.${pname} = {
        enable = lib.mkEnableOption "${pname} shell";

        package = lib.mkOption {
          type = lib.types.package;
          default = package;
          defaultText = lib.literalExpression "pkgs.${pname}";
          description = "The ${pname} package to use.";
        };

        histFile = lib.mkOption {
          type = lib.types.str;
          default = "$HOME/.${pname}_history";
          description = "Path to the history file. Evaluated at shell runtime.";
        };

        histSize = lib.mkOption {
          type = lib.types.int;
          default = 2000;
          description = "Number of history lines to keep in memory.";
        };

        shellAliases = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "Aliases to define in interactive shells.";
        };

        initExtra = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Additional commands for interactive shell init.";
        };

        # internally assembled — do not set manually
        shellInit = lib.mkOption {
          type = lib.types.lines;
          default = "";
          internal = true;
          visible = false;
        };

        loginShellInit = lib.mkOption {
          type = lib.types.lines;
          default = "";
          internal = true;
          visible = false;
        };

        interactiveShellInit = lib.mkOption {
          type = lib.types.lines;
          default = "";
          internal = true;
          visible = false;
        };
      };

      config = lib.mkIf cfg.enable {
        environment.systemPackages = [ cfg.package ];

        environment.variables.ENV = lib.mkDefault "/etc/${etcRcPath}";
        environment.variables.LANG = lib.mkDefault "C.UTF-8";

        programs.${pname}.shellInit = ''
          if [ -z "$__NIX_DARWIN_SET_ENVIRONMENT_DONE" ]; then
            . ${config.system.build.setEnvironment}
          fi
          ${config.environment.shellInit}
        '';

        programs.${pname}.loginShellInit = config.environment.loginShellInit;

        programs.${pname}.interactiveShellInit = config.environment.interactiveShellInit;

        environment.etc.${etcRcPath}.text = ''
          # /etc/${etcRcPath}: DO NOT EDIT -- this file has been generated automatically.
          # This file is read for interactive shells.

          # Only execute this file once per shell.
          if [ -n "$__ETC_${PNAME}RC_SOURCED" ]; then return; fi
          __ETC_${PNAME}RC_SOURCED=1

          # If /etc/profile was not loaded in a parent process, source it.
          if [ -z "$__ETC_PROFILE_DONE" ]; then
            . /etc/profile
          fi

          # Setup command line history.
          HISTSIZE=${toString cfg.histSize}
          HISTFILE=${cfg.histFile}

          # Safe defaults.
          set -o noclobber
          PS1="''${USER}@''${HOSTNAME}:''${PWD}$ "

          . ${config.system.build.setAliases}

          ${cfg.interactiveShellInit}

          # Read system-wide modifications.
          if test -f /etc/${etcRcPath}.local; then
            . /etc/${etcRcPath}.local
          fi

          [ -r "$HOME/${homeRcPath}" ] && . "$HOME/${homeRcPath}"
        '';

        environment.etc."profile".text = ''
          # /etc/profile: DO NOT EDIT -- this file has been generated automatically.
          # This file is read for login shells.

          # Only execute this file once per shell.
          if [ -n "$__ETC_PROFILE_SOURCED" ]; then return; fi
          __ETC_PROFILE_SOURCED=1

          # Prevent this file from being sourced by interactive non-login child shells.
          export __ETC_PROFILE_DONE=1

          if [ -x /usr/libexec/path_helper ]; then
            eval `/usr/libexec/path_helper -s`
          fi

          ${cfg.shellInit}

          ${cfg.loginShellInit}

          # Read system-wide modifications.
          if test -f /etc/profile.local; then
            . /etc/profile.local
          fi

          # Escape hatch for bash on darwin
          if [ "''${BASH-no}" != "no" ]; then
            [ -r /etc/bashrc ] && . /etc/bashrc
          elif [ -r "$ENV" ]; then
            . "$ENV"
          fi
        '';

        environment.etc."profile".knownSha256Hashes = [
          "a3fe9f414586c0d3cacbe3b6920a09d8718e503bca22e23fef882203bf765065" # macOS
        ];
      };
    };

  homeManagerModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      PNAME = lib.toUpper pname;
      cfg = config.programs.${pname};

      aliasesStr = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (k: v: "alias ${k}=${lib.escapeShellArg v}") cfg.shellAliases
      );

      sessionVariablesStr = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg (toString v)}") cfg.sessionVariables
      );
    in
    {
      options.programs.${pname} = {
        enable = lib.mkEnableOption "${pname} shell";

        package = lib.mkOption {
          type = lib.types.package;
          default = package;
          defaultText = lib.literalExpression "pkgs.${pname}";
          description = "The ${pname} package to use.";
        };

        histFile = lib.mkOption {
          type = lib.types.str;
          default = "$HOME/.${pname}_history";
          description = "Path to the history file. Evaluated at shell runtime.";
        };

        histSize = lib.mkOption {
          type = lib.types.int;
          default = 2000;
          description = "Number of history lines to keep in memory.";
        };

        shellAliases = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "Aliases to define in interactive shells.";
        };

        sessionVariables = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.oneOf [
              lib.types.str
              lib.types.int
              lib.types.path
            ]
          );
          default = { };
          description = "Environment variables to export at login.";
        };

        profileExtra = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Additional commands for login shell init.";
        };

        initExtra = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Additional commands for interactive shell init.";
        };

        logoutExtra = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = ''
            Commands to run on shell exit. When non-empty, generates a logout
            file and wires it into the interactive init via a trap.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        home.packages = [ cfg.package ];

        programs.${pname}.initExtra = lib.mkIf (cfg.logoutExtra != "") (
          lib.mkAfter ''
            trap ". $HOME/.${pname}_logout" EXIT
          ''
        );

        home.file.".profile".text = ''
          # ~/.profile: DO NOT EDIT -- this file has been generated automatically.

          . "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh"

          ${sessionVariablesStr}

          ${cfg.profileExtra}
        '';

        home.file.${homeRcPath}.text = ''
          # ~/.${homeRcPath}: DO NOT EDIT -- this file has been generated automatically.

          # Only execute this file once per shell.
          if [ -n "$__HOME_${PNAME}RC_SOURCED" ]; then return; fi
          __HOME_${PNAME}RC_SOURCED=1

          # Commands that should be applied only for interactive shells.
          case $- in
            *i*) ;;
            *) return ;;
          esac

          # Setup command line history.
          HISTSIZE=${toString cfg.histSize}
          HISTFILE=${cfg.histFile}

          ${aliasesStr}

          ${cfg.initExtra}
        '';

        home.file.".${pname}_logout" = lib.mkIf (cfg.logoutExtra != "") {
          text = ''
            # ~/.${pname}_logout: DO NOT EDIT -- this file has been generated automatically.

            ${cfg.logoutExtra}
          '';
        };
      };
    };
}
