{
  description = "Flake utils demo";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    compcert.url = "github:AbsInt/CompCert/v3.13.1";
    compcert.flake = false;
  };


  outputs = { self, nixpkgs, flake-utils, compcert }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system: # "aarch64-linux"
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

            # Nix stdenv without any Cc for the specific target
            targetStdenvNoCC = pkgs.pkgsCross.${stdenvMap.${stdenvKey}}.stdenvNoCC;

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
              targetCC = targetStdenv.cc;
            })
            refinedTargets;

        # for each target, get the refinements and flatten all into one big list
        targetsFinal = lib.flatten (builtins.map getTargetRefinements targets);

        # build a version of CompCert
        #
        # args:
        # - target: the target to build for. Run ./configure -help to get a list of targets
        # - targetCC: a C-compiler for the target. This unfortunately required, ccomp can not generate binaries completely alone, it needs another C compiler and its bintools.
        buildCompcert = { target, targetCC }: pkgs.stdenv.mkDerivation {
          pname = "CompCert-${target}";
          version = "3.13.1";
          src = compcert;
          nativeBuildInputs = with pkgs; [
            coq_8_16
            ocaml
            ocamlPackages.menhir
            ocamlPackages.menhirLib
            ocamlPackages.findlib
            # really must be targetCC, not targetCC.cc! We also need the targetCC bintools etc.
            targetCC
            # makeWrapper
          ];

          configurePhase = ''
            ./configure -prefix $out \
              -toolprefix ${targetCC.targetPrefix} \
              ${target}
          '';

          # ccomp needs an actual gcc in order to generate the final binaries
          # postFixup = ''
          #   wrapProgram $out/bin/ccomp \
          #     --suffix PATH : ${lib.makeBinPath [ targetCC ]} \
          #     --add-flags '-T ${targetCC.cc}/bin/${targetCC.targetPrefix}ld'
          # '';

          enableParallelBuilding = true;
          passthru = { inherit targetCC; };
          meta = with lib; {
            description = "The CompCert C verified compiler, a high-assurance compiler";
            homepage = "https://compcert.org/";
            license = licenses.unfree;
            platforms = platforms.all;
            maintainers = with maintainers; [ wucke13 ];
            changelog = "https://github.com/AbsInt/CompCert/blob/master/Changelog.md";
          };
        };

        wrapCompcert = { ccompDrv, stdenv }: pkgs.stdenvNoCC.mkDerivation {
          name = "compcert-wrapped";
          dontUnpack = true;
          dontBuild = true;
          nativeBuildInputs = with pkgs; [ makeWrapper ];
          installPhase = ''
            mkdir --parent -- $out/{bin,nix-support}
            makeWrapper ${ccompDrv}/bin/ccomp $out/bin/ccomp \
              --suffix PATH : ${lib.makeBinPath [ ccompDrv.targetCC.cc ]}
          '';
          # --add-flags '-T ${ccompDrv.targetCC.cc}/bin/${ccompDrv.targetCC.targetPrefix}gcc'
          # --add-flags '-I${lib.getDev stdenv.cc.libc}/include' \
        };

        cross-pkgs = pkgs.pkgsCross.aarch64-multiplatform-musl;

        # this is really finicky, not sure if we should use it
        cross-cc = pkgs.wrapCCWith rec {
          inherit (cross-pkgs) stdenvNoCC;
          inherit (cross-pkgs.stdenv.cc) bintools libc;

          cc = wrapCompcert { ccompDrv = self.packages.${system}.compcert-aarch64-linux; stdenv = null; };
          name = "ccomp";
          # NOTE $out/nix-support/cc-cflags for extra flags
          # NOTE as well cc-ldflags

          # pkgs/build-support/cc-wrapper/cc-wrapper.sh does only support wrapping gcc or clang.
          # Therefore we have to as for ccomp wrapping ourself.
          #
          # ccomp does not understand the -B flag
          extraBuildCommands = ''
            wrap ${stdenvNoCC.hostPlatform.config}-cc $wrapper $ccPath/ccomp
            sed '/-B/d' -i $out/nix-support/{add-flags.sh,cc-cflags,libc-crt1-cflags}
          '';
          # shopt -s extglob
          # NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE//-frandom-seed=+([[:alnum:]])}"
          # shopt -u extglob

          nixSupport.setup-hook =
            lib.strings.escapeShellArg (builtins.map (x: x + "\n") [
              "export CC=${stdenvNoCC.hostPlatform.config}-cc"

              # compcert does not understand the -frandom-seed flag, thus we silently discard it from NIX_CFLAGS_COMPILE
              "shopt -s extglob"
              "NIX_CFLAGS_COMPILE=${ "\"\${NIX_CFLAGS_COMPILE//-frandom-seed=+([[:alnum:]])}" }\""
              "shopt -u extglob"


              # "NIX_CFLAGS_COMPILE=\"-T ${cc.targetCC}/bin/${cc.targetCC.targetPrefix}ld $NIX_CFLAGS_COMPILE\""
              # "export PATH=\"$PATH:${cc.targetCC}/bin/\""
            ]);
        };

        cross-stdenv = cross-pkgs.overrideCC cross-pkgs.stdenv cross-cc;
      in
      rec {
        packages = listToAttrs (map
          ({ target, ... }@t: {
            name = "compcert-" + target;
            value = buildCompcert t;
          })
          targetsFinal);

        devShells.default = pkgs.mkShellNoCC {
          # Lessons learned
          # ccomp wants a aarch64-none-elf-gcc
          #
          # ccomp -c main.c -o main.o -I$(nix-get-store-path pkgsCross.aarch64-multiplatform-musl.stdenv.cc.libc_dev)/include
          #
          # aarch64-unknown-linux-musl-gcc -static -o main main.oi
          NIX_CFLAGS_COMPILE = "";
          hardeningDisable = [ "all" ];
          nativeBuildInputs = [
            # pkgs.pkgsCross.aarch64-multiplatform-musl.stdenv.cc
            # pkgs.pkgsCross.aarch64-embedded.stdenv.cc.cc
            # packages.compcert-aarch64-linux
            pkgs.qemu
          ];
        };

        checks = {
          nixpkgs-fmt = pkgs.runCommand "nixpkgs-fmt"
            {
              nativeBuildInputs = [ pkgs.nixpkgs-fmt ];
            } "nixpkgs-fmt --check ${./.}; touch $out";
          inherit cross-cc; # cross-cc-homemade;
          example_1 = cross-stdenv.mkDerivation {
            name = "example";
            src = ./example;
            hardeningDisable = [ "all" ];
            buildPhase = ''
              runHook preInstall

              mkdir --parent -- $out/bin

              set -x
              # make sure we use the right C-compiler, ccomp
              $CC -version

              $CC -v test_1.c -o $out/bin/test_1
              set +x

              runHook postInstall
            '';
          };
        };

        hydraJobs = packages // checks;
      });
}

