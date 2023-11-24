{
  description = "Flake utils demo";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    compcert.url = "github:AbsInt/CompCert/v3.13.1";
    compcert.flake = false;
  };

  outputs = { self, nixpkgs, flake-utils, compcert }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "x86_64-darwin" "x86_64-windows" ] (system:
      let
        inherit (nixpkgs) lib;

        inherit (builtins) listToAttrs map;

        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        # get targets:
        # ./configure -help | awk '/Supported targets:/,/^$/ {if ($1 == "Supported" || $1 == "") next; printf "\"%s\" # ", $1; for (i = 2; i <= NF; i++) printf "%s ", $i; printf "\n"} {next}'

        # available targets
        targets = [
          "ppc-eabi" # (PowerPC, EABI with GNU/Unix tools)
          # "ppc-eabi-diab" # (PowerPC, EABI with Diab tools)
          "ppc-linux" # (PowerPC, Linux)
          "arm-eabi" # (ARM, EABI, little endian)
          "arm-linux" # (ARM, EABI, little endian)
          "arm-eabihf" # (ARM, EABI using hardware FP registers, little endian)
          "arm-hardfloat" # (ARM, EABI using hardware FP registers, little endian)
          "armeb-eabi" # (ARM, EABI, big endian)
          "armeb-linux" # (ARM, EABI, big endian)
          "armeb-eabihf" # (ARM, EABI using hardware FP registers, big endian)
          "armeb-hardfloat" # (ARM, EABI using hardware FP registers, big endian)
          "x86_32-linux" # (x86 32 bits, Linux)
          "x86_32-bsd" # (x86 32 bits, BSD)
          "x86_64-linux" # (x86 64 bits, Linux)
          "x86_64-bsd" # (x86 64 bits, BSD)
          # "x86_64-macos" # (x86 64 bits, MacOS X)
          "x86_64-cygwin" # (x86 64 bits, Cygwin environment under Windows)
          "rv32-linux" # (RISC-V 32 bits, Linux)
          "rv64-linux" # (RISC-V 64 bits, Linux)
          "aarch64-linux" # (AArch64, i.e. ARMv8 in 64-bit mode, Linux)
          # "aarch64-macos" # (AArch64, i.e. Apple silicon, MacOS)
        ] ++ (lib.optionals pkgs.targetPlatform.isDarwin [ "x86_64-macos" "aarch64-macos" ]);

        refinements = {
          arm = [
            "armv6-" # ARMv6   + VFPv2       (Thumb mode not supported)
            "armv6t2-" # ARMv6T2 + VFPv2
            "armv7a-" # ARMv7-A + VFPv3-d16   (default for arm-)
            "armv7r-" # ARMv7-R + VFPv3-d16
            "armv7m-" # ARMv7-M + VFPv3-d16
          ];
          armeb = [
            "armebv6-" # ARMv6   + VFPv2       (Thumb mode not supported)
            "armebv6t2-" # ARMv6T2 + VFPv2
            "armebv7a-" # ARMv7-A + VFPv3-d16   (default for armeb-)
            "armebv7r-" # ARMv7-R + VFPv3-d16
            "armebv7m-" # ARMv7-M + VFPv3-d16
          ];
          ppc = [
            "ppc64-" # PowerPC 64 bits
            "e5500-" # Freescale e5500 core (PowerPC 64 bit, EREF extensions)
          ];
        };

        # mapping from compcert prefixes to nixos package sets in pkgsCross
        stdenvMap = {
          ppc = "ppc-embedded";
          arm = "arm-embedded";
          armeb = "arm-embedded";
          x86_32 = "i686-embedded";
          x86_64 = "x86_64-embedded";
          rv32 = "riscv32-embedded";
          rv64 = "riscv64-embedded";
          aarch64 = "aarch64-embedded";

          # take precedence
          aarch64-macos = "aarch64-darwin";
          x86_64-macos = "x86_64-darwin";
        };

        # takes one target and generates a list including the target and all
        # its refinements, if any
        getTargetRefinements = baseTarget:
          let
            inherit (builtins) elemAt hasAttr map;
            inherit (lib) optionals removePrefix splitString;

            # prefix of a target, i. e. "arm" for "arm-eabihf"
            targetPrefix = elemAt (splitString "-" baseTarget) 0;

            # name of the pkgs in pkgs.pkgsCross for baseTarget
            stdenvKey = if stdenvMap ? ${baseTarget} then baseTarget else targetPrefix;

            # Nix stdenv for the specific target
            targetStdenv = pkgs.pkgsCross.${stdenvMap.${stdenvKey}}.stdenv;

            # target name without a prefix, i.e "eabihf" for "arm-eabihf"
            targetWithoutPrefix = removePrefix "${targetPrefix}-" baseTarget;

            # refinement prefixes for a target, or an empty list
            refinementPrefixes = optionals (hasAttr targetPrefix refinements) refinements.${targetPrefix};

            # the refined targets, including the base target
            refinedTargets = (map (x: x + targetWithoutPrefix) refinementPrefixes)
              ++ [ baseTarget ];
          in
          map
            (refinedTarget: {
              target = refinedTarget;
              targetCc = targetStdenv.cc;
            })
            refinedTargets;

        # for each target, get the refinements and flatten all into one big list
        targetsFinal = lib.flatten (builtins.map getTargetRefinements targets);

        # build a version of CompCert
        #
        # args:
        # - target: the target to build for. Run ./configure -help to get a list of targets
        # - targetCc: a C-compiler for the target. This
        buildCompcert = { target, targetCc }: pkgs.stdenv.mkDerivation {
          pname = "CompCert-${target}";
          version = "3.13.1";
          src = compcert;
          nativeBuildInputs = with pkgs; [
            coq_8_16
            ocaml
            ocamlPackages.menhir
            ocamlPackages.menhirLib
            ocamlPackages.findlib
            targetCc
          ];

          configurePhase = ''
            ./configure -prefix $out \
              -toolprefix ${targetCc.targetPrefix} \
              ${target}
          '';

          enableParallelBuilding = true;

          meta = with lib; {
            description = "The CompCert C verified compiler, a high-assurance compiler";
            homepage = "https://compcert.org/";
            license = licenses.unfree;
            platforms = platforms.all;
            maintainers = with maintainers; [ wucke13 ];
            changelog = "https://github.com/htop-dev/htop/blob/${version}/Changelog.md";
          };
        };

        cross-pkgs = pkgs.pkgsCross.aarch64-multiplatform-musl;
        cross-cc = cross-pkgs.wrapCCWith {
          cc = self.packages.${system}.compcert-aarch64-linux;
          inherit (cross-pkgs.stdenv.cc) bintools libc;
          name = "ccomp";
          # NOTE $out/nix-support/cc-cflags for extra flags
          # NOTE as well cc-ldflags
          # noLibc = true;
        };
        # cross-cc = cross-pkgs.stdenv.cc.override {
        #   name = "ccomp";
        #   extraPackages = [
        #     compcert-utils.packages.${system}.compcert-aarch64-linux
        #   ];
        # };
        cross-stdenv = cross-pkgs.overrideCC cross-pkgs.stdenv cross-cc;
      in
      rec {
        packages = listToAttrs (map ({ target, ... }@t: { name = "compcert-" + target; value = buildCompcert t; }) targetsFinal);

        devShells.default = pkgs.mkShellNoCC {
          # Lessons learned
          # ccomp wants a aarch64-none-elf-gcc
          #
          # ccomp -c main.c -o main.o -I$(nix-get-store-path pkgsCross.aarch64-multiplatform-musl.stdenv.cc.libc_dev)/include
          #
          # aarch64-unknown-linux-musl-gcc -static -o main main.o
          nativeBuildInputs = [
            pkgs.pkgsCross.aarch64-multiplatform-musl.stdenv.cc
            pkgs.pkgsCross.aarch64-embedded.stdenv.cc.cc
            packages.compcert-aarch64-linux
          ];
        };

        checks = {
          nixpkgs-fmt = pkgs.runCommand "nixpkgs-fmt"
            {
              nativeBuildInputs = [ pkgs.nixpkgs-fmt ];
            } "nixpkgs-fmt --check ${./.}; touch $out";
          example_1 = cross-stdenv.mkDerivation {
            name = "example";
            src = ./example;
            buildPhase = ''
              runHook preInstall

              mkdir --parent -- $out/bin
              echo $CC
              $CC test_1.c -o $out/bin/test_1

              runHook postInstall
            '';
          };
        };

        hydraJobs = packages // checks;
      });
}
