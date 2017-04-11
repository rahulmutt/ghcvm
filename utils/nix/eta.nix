{ mkDerivation, aeson, alex, array, base, bytestring, codec-jvm
, containers, cpphs, deepseq, directory, eta-boot, eta-boot-th
, exceptions, filepath, happy, haskeline, hpc, mtl, path, path-io
, process, stdenv, text, time, transformers, turtle, unix
, unix-compat, zip
}:
mkDerivation {
  pname = "eta";
  version = "0.0.6";
  src = ../..;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    array base bytestring codec-jvm containers cpphs deepseq directory
    eta-boot eta-boot-th exceptions filepath hpc mtl path path-io
    process text time transformers unix unix-compat zip
  ];
  libraryToolDepends = [ alex happy ];
  executableHaskellDepends = [
    array base bytestring deepseq directory filepath haskeline process
    transformers unix
  ];
  testHaskellDepends = [
    aeson base bytestring directory filepath text turtle
  ];
  license = stdenv.lib.licenses.bsd3;
}
