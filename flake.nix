{
  description = "First-class NixOS / nix-darwin / home-manager support for POSIX shells";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
    in
    {
      lib = import ./lib;

      # Example pre-built modules (optional — consumers usually generate their own).
      # nixosModules.default = ...;
      # homeManagerModules.default = ...;
      # darwinModules.default = ...;
    };
}
