{
  description = "openbirds — privacy-first, end-to-end encrypted, pixel-art self-care companion. Written in Koka.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # kklib is the Koka C runtime. nixpkgs builds it as a separate
        # derivation but only exposes it through `koka.buildInputs`, so
        # we pluck it back out by pname. Multi-output: `.out` carries the
        # static library, `.dev` carries the headers.
        kklib = pkgs.lib.findFirst
          (p: (p.pname or "") == "kklib")
          (throw "kklib not found in koka.buildInputs — nixpkgs layout changed")
          pkgs.koka.buildInputs;
      in
      {
        packages.default = pkgs.callPackage ./nix/package.nix { };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            koka
            xcodegen
            just
            git
            jq
          ];

          shellHook = ''
            # Stable handles for the kklib runtime so the Justfile doesn't
            # have to grep nix store paths. These follow nixpkgs upgrades
            # automatically when flake.lock is bumped.
            export OPENBIRDS_KKLIB_LIB="${kklib.out}/lib"
            export OPENBIRDS_KKLIB_INCLUDE="${kklib.dev}/include"

            echo "openbirds dev shell"
            echo "  koka     : $(koka --version 2>&1 | head -1)"
            echo "  xcodegen : $(xcodegen --version 2>&1 | head -1)"
            echo "  swift    : $(swift --version 2>&1 | head -1)"
            echo "  kklib    : $OPENBIRDS_KKLIB_LIB"
            echo
            echo "Run 'just' for the task list."
          '';
        };
      }
    );
}
