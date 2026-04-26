{
  description = "First-class NixOS / nix-darwin / home-manager support for POSIX shells";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    {
      lib = import ./lib;
    };
}
