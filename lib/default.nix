{
  # Main entry point: generates nixosModule, homeManagerModule, and darwinModule
  # for a POSIX-compatible shell.
  #
  # Usage (inside a NixOS / home-manager / nix-darwin module):
  #   shnix.lib.mkPosixShellModule {
  #     name = "ksh";
  #     package = pkgs.ksh93;
  #     initFiles = { ... };
  #   }
  #
  # Returns: { nixosModule, homeManagerModule, darwinModule }
  mkPosixShellModule = import ./mk-posix-shell.nix;
}
