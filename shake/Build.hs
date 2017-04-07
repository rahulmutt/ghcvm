{-# GHC_OPTIONS -XNoOverloadedStrings #-}
import Data.List(intercalate)
import Development.Shake
import Development.Shake.Command
import Development.Shake.FilePath
import Development.Shake.Util
import System.Directory (createDirectoryIfMissing, getAppUserDataDirectory,
                         createDirectory, removeDirectory, findExecutable)
import System.Console.GetOpt
import Control.Monad (forM_, when)
import Data.List (partition, stripPrefix, isPrefixOf, isInfixOf)
import Data.Maybe (mapMaybe, isJust)
import Distribution.InstalledPackageInfo
import Distribution.ParseUtils
import Distribution.ModuleName (fromString)
import System.Info (os)
import System.Exit(ExitCode(..))
import GHC.IO.Exception(ExitCode)

rtsDir = "rts"
genBuild x = x </> "build"
rtsBuildDir = rtsDir </> "build"
rtsIncludeDir = rtsDir </> "include"
rtsSrcDir = rtsDir </> "src"
build x = rtsBuildDir </> x
debug x = liftIO $ print x
rtsjar = libJarPath "rts"
top x = "../../" ++ x
testsDir = "tests"
packageConfDir dir = dir </> "package.conf.d"
externalDepLibs = ["ghc-boot"]

etaIncludePath :: FilePath -> FilePath
etaIncludePath = (</> "include")

getInstallDir :: Action FilePath
getInstallDir = fmap (</> "bin") $ liftIO $ getAppUserDataDirectory "local"

getEpmDir :: Action FilePath
getEpmDir = liftIO $ getAppUserDataDirectory "epm"

getEtaRoot :: Action FilePath
getEtaRoot = liftIO $ getAppUserDataDirectory "eta"

libraryDir = "libraries"
library x = libraryDir </> x

libName :: String -> String
libName lib = "HS" ++ lib ++ ".jar"

libCustomBuildDir :: String -> FilePath
libCustomBuildDir lib = libraryDir </> lib </> "build"

libJarPath :: String -> FilePath
libJarPath lib = libCustomBuildDir lib </> libName lib

createDirIfMissing = liftIO . createDirectoryIfMissing True

getDependencies :: String -> [String]
getDependencies "ghc-prim" = ["rts"]
getDependencies "base" = ["ghc-prim", "integer"]
getDependencies "integer" = ["ghc-prim"]
getDependencies "ghci" = ["ghc-boot", "base", "template-haskell"]
getDependencies "ghc-boot" = ["base"]
getDependencies "ghc-boot-th" = ["base"]
getDependencies "template-haskell" = ["base"]
getDependencies _ = []

topologicalDepsSort :: [String] -> (String -> [String]) -> [String]
topologicalDepsSort xs deps = sort' xs []
 where sort' [] ys = reverse ys
       sort' xs ys = sort' xs2 (xs1 ++ ys)
         where (xs1, xs2) = partition (all (`elem` ys) . deps) xs


buildConf :: String -> FilePath -> FilePath -> Action ()
buildConf lib confSrc confDst = do
  rootDir <- getEtaRoot
  confStr <- readFile' confSrc
  case parseInstalledPackageInfo confStr of
    ParseOk warnings ipi -> do
      mapM_ (putNormal . showPWarning confSrc) warnings
      let ipi' = ipi { hsLibraries = ["HS" ++ lib]
                     , pkgRoot = Just rootDir
                     , importDirs = [rootDir </> lib]
                     , libraryDirs = [rootDir </> lib]
                     , includeDirs = if lib == "rts" then
                                       [etaIncludePath rootDir]
                                     else
                                       [] }
      writeFile' confDst $ showInstalledPackageInfo ipi'
    ParseFailed err -> case locatedErrorMsg err of
                         (Nothing, s) -> putNormal s
                         (Just l, s) -> putNormal $ show l ++ ": " ++ s

fixGhcPrimConf :: Action ()
fixGhcPrimConf = do
  rootDir <- getEtaRoot
  let confDir = packageConfDir rootDir
  (ghcPrimConf':_) <- fmap (filter ("ghc-prim" `isPrefixOf`))
                    $ getDirectoryFiles confDir ["*.conf"]
  let ghcPrimConf = confDir </> ghcPrimConf'
  confStr <- readFile' ghcPrimConf
  case parseInstalledPackageInfo confStr of
    ParseOk warnings ipi -> do
      mapM_ (putNormal . showPWarning ghcPrimConf) warnings
      let ipi' = ipi { exposedModules = ExposedModule (fromString "GHC.Prim")
                                                      Nothing Nothing
                                      : exposedModules ipi }
      writeFile' ghcPrimConf $ showInstalledPackageInfo ipi'
      unit $ cmd "eta-pkg recache"
    ParseFailed err -> case locatedErrorMsg err of
                         (Nothing, s) -> putNormal s
                         (Just l, s) -> putNormal $ show l ++ ": " ++ s

buildLibrary :: Bool -> String -> [String] -> Action ()
buildLibrary debug lib deps = do
  let dir = library lib
      installFlags = if lib == "ghc-prim" || lib == "base"
                     then ["--solver=topdown"]
                          -- NOTE: For ghc-prim & base, cabal fails if the modular solver is
                          --       used so we use the top-down solver to make it work.
                     else []
      configureFlags = if debug
                       then ["--enable-optimization=0"
                            ,"--eta-options=-ddump-to-file -ddump-stg -dumpdir=dump"]
                       else ["--enable-optimization=2"]

      -- libCmd = unit . cmd (Cwd dir)
  when (lib == "rts") $ need [rtsjar]
  when (not $ lib `elem` externalDepLibs) $ unit $ cmd (Cwd dir) "epm configure" configureFlags
  unit $ cmd (Cwd dir) "epm install" installFlags
  when (lib == "ghc-prim") $ fixGhcPrimConf
  return ()

testSpec :: FilePath -> Action ()
testSpec specPath = do
  rootDir <- getEtaRoot
  specStr <- readFile' specPath
  let (command, output') = break (== '\n') specStr
      expectedOutput     = drop 1 output'
      testHome           = takeDirectory specPath
      packageDir         = packageConfDir rootDir
      testBuildDir       = genBuild testHome
  createDir testBuildDir
  unit $ cmd [Cwd testHome, AddEnv "ETA_PACKAGE_PATH" packageDir]
             "eta -shared" ["-outputdir", "build"] ["-o", jarTestFile] command mainTestFile

  let classPathsAll = jarTestFile : map libJar ["base", "rts", "ghc-prim", "integer"]
      libJar lib = rootDir </> lib </> ("HS" ++ lib ++ ".jar")
      classPathFolded = intercalate ":" classPathsAll

  Stdout actualOutput <- cmd (Cwd testHome) "java" ["-classpath", classPathFolded] "eta.main"
  --removeFilesAfter testBuildDir ["//*"]
  if expectedOutput == actualOutput then
    putNormal $ "Test " ++ specPath ++ " passed."
  else do
    putNormal $ "Test " ++ specPath ++ " failed."
    putNormal $ "Actual:"
    putNormal $ actualOutput
    putNormal $ "Expected:"
    putNormal $ expectedOutput
  where mainTestFile = fileName -<.> "hs"
        jarTestFile  = "build" </> (fileName -<.> "jar")
        fileName     = takeBaseName specPath

createDir :: FilePath -> Action ()
createDir path = liftIO $ createDirectoryIfMissing True path

copyFileWithDir :: FilePath -> FilePath -> Action ()
copyFileWithDir src dst = do
  createDir (takeDirectory src)
  createDir (takeDirectory dst)
  copyFile' src dst

getLibs :: Action [String]
getLibs = getDirectoryDirs libraryDir

dropDirectoryN :: Int -> FilePath -> FilePath
dropDirectoryN n = head . drop n . iterate dropDirectory1

flags = [Option "" ["debuginfo"] (NoArg $ Right True) "Run with debugging information."]

-- TODO: Make the build script cleaner
main :: IO ()
main = shakeArgsWith shakeOptions{shakeFiles=rtsBuildDir} flags $ \flags targets -> return $ Just $ do

    if null targets
      then want [rtsjar]
      else want targets

    let debug = case flags of
          (x:_) -> True
          _     -> False

    phony "install" $ do
      rootDir <- getEtaRoot
      exists <- doesDirectoryExist rootDir
      if exists then
        putNormal $ "eta already installed. To perform a clean install,\n"
                 ++ "run 'eta-build uninstall' followed by 'eta-build"
                 ++ " install'."
      else do
        liftIO $ createDirectory rootDir
        let root x = rootDir </> x
        unit $ cmd ["eta-pkg","init",packageConfDir rootDir]
        unit $ cmd "epm update"
        epmDir <- getEpmDir
        copyFile' "utils/coursier/coursier" $ epmDir </> "coursier"
        libs <- getLibs
        let sortedLibs = topologicalDepsSort libs getDependencies
        forM_ sortedLibs $ \lib ->
          buildLibrary debug lib (getDependencies lib)

    phony "rts-clean" $ do
      liftIO $ removeFiles (libCustomBuildDir "rts") ["//*"]
      need [rtsjar]
      let libDir = libraryDir </> "rts"
      unit $ cmd (Cwd libDir) "epm clean"
      unit $ cmd (Cwd libDir) "epm build"
      epmDir <- getEpmDir
      let epmLibDir = epmDir </> "lib"
      -- @VERSION_CHANGE@
      epmLibDir' <- fmap (head . filter ("eta-0.0.5" `isInfixOf`))
                   $ getDirectoryContents epmLibDir
      copyFile' (libDir </> "dist" </> "build" </> "HSrts-0.1.0.0.jar")
                (epmLibDir </> epmLibDir' </> "rts-0.1.0.0" </> "HSrts-0.1.0.0.jar")

    phony "test" $ do
      specs <- getDirectoryFiles "" ["//*.spec"]
      mapM_ testSpec specs

    phony "testclean" $ do
      specs <- getDirectoryFiles "" ["//*.spec"]
      mapM_ (\spec -> removeFilesAfter (takeDirectory spec </> "build") ["//*"]) specs

    phony "uninstall" $ do
      rootDir <- getEtaRoot
      putNormal "Cleaning files in ~/.eta"
      removeFilesAfter rootDir ["//*"]

    phony "reinstall" $ do
      need ["uninstall"]
      need ["install"]

    phony "clean" $ do
      putNormal "Cleaning files in rts/build, libraries/*/dist"
      removeFilesAfter rtsBuildDir ["//*"]
      libs <- getLibs
      forM_ libs $ \lib -> do
        let libDir = libraryDir </> lib
        unit $ cmd (Cwd libDir) "epm clean"

    rtsjar %> \out -> do
      createDirIfMissing rtsBuildDir
      cs <- getDirectoryFiles rtsSrcDir ["//*.java"]
      -- TODO: Setup a debug build
      let javacFlags = if debug then ["-g"] else []
      unit $ cmd (Cwd rtsSrcDir) "javac" "-XDignore.symbol.file" javacFlags "-d" (top rtsBuildDir) cs
      classfiles <- getDirectoryFiles rtsBuildDir ["//*.class"]
      unit $ cmd (Cwd rtsBuildDir) "jar cf" (top out) classfiles
