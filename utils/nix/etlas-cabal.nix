{ mkDerivation, array, base, binary, bytestring, containers
, deepseq, directory, filepath, pretty, process, stdenv, time, unix
}:
mkDerivation {
  pname = "etlas-cabal";
  version = "1.0.0.0";
  src = ../../etlas/etlas-cabal;
  libraryHaskellDepends = [
    array base binary bytestring containers deepseq directory filepath
    pretty process time unix
  ];
  homepage = "https://etlas.typelead.com";
  description = "Package management for Eta";
  license = stdenv.lib.licenses.bsd3;
}
