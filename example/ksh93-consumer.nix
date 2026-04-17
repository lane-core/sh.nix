# Example: how a ksh93 flake would consume sh.nix to provide programs.ksh
# modules for NixOS, nix-darwin, and home-manager.

{
  config,
  lib,
  pkgs,
  shnix,
  ...
}:

let
  # Generate the three modules from sh.nix.
  kshModules = shnix.lib.mkPosixShellModule {
    name = "ksh";
    package = pkgs.ksh93;

    initFiles = {
      profile = {
        # Don't write /etc/profile on NixOS — bash already manages it.
        nixos = null;
        homeManager = {
          homePath = ".profile";
        };
        darwin = {
          etcName = "profile";
        };
        when = "login";
        envVar = null;
      };

      rc = {
        nixos = {
          etcName = "kshrc";
        };
        homeManager = {
          homePath = ".kshrc";
        };
        darwin = {
          etcName = "kshrc";
        };
        when = "interactive";
        envVar = "ENV"; # login file will export ENV=/etc/kshrc
      };
    };

    # ksh93-specific options layered on top of the POSIX base.
    extraOptions = {
      options.programs.ksh = {
        histfile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "\${HOME}/.ksh_history";
          description = ''
            Path to the ksh history file.
          '';
        };

        histsize = lib.mkOption {
          type = lib.types.int;
          default = 10000;
          description = ''
            Number of history entries to keep.
          '';
        };
      };
    };

    # ksh93-specific config that uses the extra options.
    extraConfig = {
      config.programs.ksh.interactiveShellInit = lib.mkAfter ''
        # ksh93 history configuration
        HISTFILE="${config.programs.ksh.histfile}"
        HISTSIZE=${toString config.programs.ksh.histsize}
      '';
    };
  };

in
{
  # Re-export for the flake outputs.
  nixosModule = kshModules.nixosModule;
  homeManagerModule = kshModules.homeManagerModule;
  darwinModule = kshModules.darwinModule;
}
