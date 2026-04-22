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
        etcName = "profile";
        homePath = ".profile";
        when = "login";
        envVar = null;
      };

      rc = {
        etcName = "kshrc";
        homePath = ".kshrc";
        when = "interactive";
        envVar = "ENV"; # login file will export ENV pointing to the rc file
      };
    };

    # ksh93-specific programmable options.
    # Each entry declares an option that the user can set in programs.ksh,
    # and a generator that produces shell code injected into the target init file.
    programmableOptions = {
      shellOptions = {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Shell options to enable via set -o";
        target = "interactiveShellInit";
        generator = opts: lib.concatMapStringsSep "\n" (o: "set -o ${o}") opts;
      };

      histfile = {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Path to the ksh history file";
        target = "interactiveShellInit";
        generator = path: ''HISTFILE="${path}"'';
      };

      histsize = {
        type = lib.types.int;
        default = 10000;
        description = "Number of history entries to keep";
        target = "interactiveShellInit";
        generator = n: "HISTSIZE=${toString n}";
      };
    };
  };

in
{
  # Re-export for the flake outputs.
  nixosModule = kshModules.nixosModule;
  homeManagerModule = kshModules.homeManagerModule;
  darwinModule = kshModules.darwinModule;
}
