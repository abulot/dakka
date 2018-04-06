{ nixpkgs ? import <nixpkgs> {} }:

let
  inherit (nixpkgs) pkgs;
  f = { mkDerivation, base, mtl, stdenv, transformers, containers, contravariant, distributed-process, network-transport-tcp }:
      mkDerivation {
        pname = "dakka";
        version = "0.0.1";
        src = ./.;
        libraryHaskellDepends = [ base transformers mtl contravariant containers distributed-process network-transport-tcp ];
        description = "dakka";
        license = stdenv.lib.licenses.mit;
      };

  drv = pkgs.haskell.packages.ghc841.callPackage f {};
in
  if pkgs.lib.inNixShell then drv.env else drv

