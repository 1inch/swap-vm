{
  description = "swap-vm-verified dev environment with Foundry and Kontrol";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    foundry.url = "github:shazow/foundry.nix/stable";
    foundry.inputs.nixpkgs.follows = "nixpkgs";
    foundry.inputs.flake-utils.follows = "flake-utils";
    kontrol.url = "github:runtimeverification/kontrol";
  };

  outputs = { self, nixpkgs, flake-utils, foundry, kontrol }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ foundry.overlay ];
        };
      in
      {
        devShells.default = with pkgs; mkShell {
          buildInputs = [
            # Foundry
            foundry-bin

            # Kontrol (formal verification)
            kontrol.packages.${system}.kontrol

            nodejs
            yarn-berry
          ];
        };
      });
}
