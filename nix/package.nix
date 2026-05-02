{ lib, stdenv, koka }:

stdenv.mkDerivation {
  pname = "openbirds-hello";
  version = "0.0.0";

  src = lib.cleanSource ./..;

  nativeBuildInputs = [ koka ];

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    koka -O2 -o hello koka/hello.kk
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp hello $out/bin/openbirds-hello
    runHook postInstall
  '';

  meta = {
    description = "openbirds Stage 0 hello world (Koka native binary)";
    license = lib.licenses.mit;
    mainProgram = "openbirds-hello";
    platforms = lib.platforms.unix;
  };
}
