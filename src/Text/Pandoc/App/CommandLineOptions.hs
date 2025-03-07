{-# LANGUAGE CPP                 #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE FlexibleContexts    #-}
{- |
   Module      : Text.Pandoc.App.CommandLineOptions
   Copyright   : Copyright (C) 2006-2022 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley@edu>
   Stability   : alpha
   Portability : portable

Does a pandoc conversion based on command-line options.
-}
module Text.Pandoc.App.CommandLineOptions (
            parseOptions
          , parseOptionsFromArgs
          , handleOptInfo
          , options
          , engines
          , setVariable
          ) where
import Control.Monad.Trans
import Control.Monad.State.Strict
import Data.Containers.ListUtils (nubOrd)
import Data.Aeson.Encode.Pretty (encodePretty', Config(..), keyOrder,
         defConfig, Indent(..), NumberFormat(..))
import Data.Bifunctor (second)
import Data.Char (toLower)
import Data.List (intercalate, sort, foldl')
#ifdef _WINDOWS
import Data.List (isPrefixOf)
#endif
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Safe (tailDef)
import Skylighting (Syntax (..), defaultSyntaxMap)
import System.Console.GetOpt
import System.Environment (getArgs, getProgName)
import System.Exit (exitSuccess)
import System.FilePath
import System.IO (stdout)
import Text.DocTemplates (Context (..), ToContext (toVal), Val (..))
import Text.Pandoc
import Text.Pandoc.Builder (setMeta)
import Text.Pandoc.App.Opt (Opt (..), LineEnding (..), IpynbOutput (..),
                            DefaultsState (..), applyDefaults,
                            fullDefaultsPath, OptInfo(..))
import Text.Pandoc.Filter (Filter (..))
import Text.Pandoc.Highlighting (highlightingStyles, lookupHighlightingStyle)
import Text.Pandoc.Scripting (ScriptingEngine (..), customTemplate)
import Text.Pandoc.Shared (safeStrRead)
import Text.Printf
import qualified Control.Exception as E
import Control.Monad.Except (ExceptT(..), runExceptT, throwError)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as B
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Text.Pandoc.UTF8 as UTF8

parseOptions :: [OptDescr (Opt -> ExceptT OptInfo IO Opt)]
             -> Opt -> IO (Either OptInfo Opt)
parseOptions options' defaults = do
  rawArgs <- map UTF8.decodeArg <$> liftIO getArgs
  prg <- liftIO getProgName
  parseOptionsFromArgs options' defaults prg rawArgs

parseOptionsFromArgs
  :: [OptDescr (Opt -> ExceptT OptInfo IO Opt)]
  -> Opt -> String -> [String] -> IO (Either OptInfo Opt)
parseOptionsFromArgs options' defaults prg rawArgs = do
  let (actions, args, unrecognizedOpts, errors) =
           getOpt' Permute options' (map UTF8.decodeArg rawArgs)

  let unknownOptionErrors =
       foldr (handleUnrecognizedOption . takeWhile (/= '=')) []
       unrecognizedOpts

  let mbArgs = case args of
                 [] -> Nothing
                 xs -> Just xs

  let adjustOpts opts =
           opts{ optInputFiles =
                   map normalizePath <$> (optInputFiles opts <> mbArgs)
               , optStandalone = -- certain other options imply standalone
                   optStandalone opts ||
                     isJust (optTemplate opts) ||
                     optSelfContained opts ||
                     not (null (optIncludeInHeader opts)) ||
                     not (null (optIncludeBeforeBody opts)) ||
                     not (null (optIncludeAfterBody opts)) }

  if (null errors && null unknownOptionErrors)
     then -- thread option data structure through all supplied option actions
       runExceptT $ adjustOpts <$> (foldl' (>>=) (return defaults) actions)
     else return $ Left $ OptError $ PandocOptionError $ T.pack $
             concat errors ++ unlines unknownOptionErrors ++
             ("Try " ++ prg ++ " --help for more information.")

-- | React to an 'OptInfo' by printing the requested information
-- and exiting or (if there was a parsing error) raising an error.
handleOptInfo :: ScriptingEngine -> OptInfo -> IO ()
handleOptInfo engine info = E.handle (handleError . Left) $ do
  case info of
    BashCompletion -> do
      datafiles <- getDataFileNames
      tpl <- runIOorExplode $
               UTF8.toString <$>
                 readDefaultDataFile "bash_completion.tpl"
      let optnames (Option shorts longs _ _) =
            map (\c -> ['-',c]) shorts ++
            map ("--" ++) longs
      let allopts = unwords (concatMap optnames options)
      UTF8.hPutStrLn stdout $ T.pack $ printf tpl allopts
          (T.unpack $ T.unwords readersNames)
          (T.unpack $ T.unwords writersNames)
          (T.unpack $ T.unwords $ map fst highlightingStyles)
          (unwords datafiles)
    ListInputFormats -> mapM_ (UTF8.hPutStrLn stdout) readersNames
    ListOutputFormats -> mapM_ (UTF8.hPutStrLn stdout) writersNames
    ListExtensions mbfmt -> do
      let formatName = fromMaybe "markdown" mbfmt
      let allExts = getAllExtensions formatName
      if formatName `notElem`
          (map fst (readers :: [(Text, Reader PandocPure)]) ++
           map fst (writers :: [(Text, Writer PandocPure)]))
         then E.throwIO $ PandocOptionError $ formatName <>
                " is not a recognized reader or writer format"
         else do
           let defExts = getDefaultExtensions formatName
           let showExt x =
                (if extensionEnabled x defExts
                    then '+'
                    else if extensionEnabled x allExts
                            then '-'
                            else ' ') : drop 4 (show x)
           mapM_ (UTF8.hPutStrLn stdout . T.pack . showExt)
              (extensionsToList allExts)
    ListHighlightLanguages -> do
      let langs = [ T.unpack (T.toLower (sShortname s))
                  | s <- M.elems defaultSyntaxMap
                  , sShortname s `notElem`
                     [T.pack "Alert", T.pack "Alert_indent"]
                  ]
      mapM_ (UTF8.hPutStrLn stdout . T.pack) (sort langs)
    ListHighlightStyles -> do
      mapM_ (UTF8.hPutStrLn stdout . fst) highlightingStyles
    PrintDefaultTemplate mbout fmt -> do
      let write = maybe (UTF8.hPutStr stdout) (UTF8.writeFile) mbout

      templ <- runIO $
               case splitExtension (T.unpack fmt) of
                    (_, "") -> do
                      -- built-in format
                      setUserDataDir Nothing
                      getDefaultTemplate fmt
                    _ -> do
                      -- format looks like a filepath => custom writer
                      components <- engineLoadCustom engine (T.unpack fmt)
                      case customTemplate components of
                        Just t  -> pure t
                        Nothing -> E.throw $ PandocNoTemplateError fmt
      case templ of
           Right t
             | T.null t -> -- e.g. for docx, odt, json:
                 E.throwIO $ PandocCouldNotFindDataFileError $ T.pack
                   ("templates/default." ++ T.unpack fmt)
             | otherwise -> write t
           Left e  -> E.throwIO e
    PrintDefaultDataFile mbout f -> do
      let write = maybe BS.putStr BS.writeFile mbout
      runIOorExplode $ readDefaultDataFile (T.unpack f) >>= liftIO . write
    PrintHighlightStyle mbout styleName -> do
       let write = maybe B.putStr B.writeFile mbout
       sty <- runIOorExplode $ lookupHighlightingStyle (T.unpack styleName)
       write $ encodePretty'
         defConfig{confIndent = Spaces 4
                  ,confCompare = keyOrder
                    (map T.pack
                     ["text-color"
                     ,"background-color"
                     ,"line-number-color"
                     ,"line-number-background-color"
                     ,"bold"
                     ,"italic"
                     ,"underline"
                     ,"text-styles"])
                  ,confNumFormat = Generic
                  ,confTrailingNewline = True} sty
    VersionInfo -> do
      prg <- getProgName
      defaultDatadir <- defaultUserDataDir
      UTF8.hPutStrLn stdout
       $ T.pack
       $ prg ++ " " ++ T.unpack pandocVersionText ++
         compileInfo ++
         "\nUser data directory: " ++ defaultDatadir ++
         ('\n':copyrightMessage)
    Help -> do
      prg <- getProgName
      UTF8.hPutStr stdout (T.pack $ usageMessage prg options)
    OptError e -> E.throwIO e
  exitSuccess

-- | Supported LaTeX engines; the first item is used as default engine
-- when going through LaTeX.
latexEngines :: [String]
latexEngines  = ["pdflatex", "lualatex", "xelatex", "latexmk", "tectonic"]

-- | Supported HTML PDF engines; the first item is used as default
-- engine when going through HTML.
htmlEngines :: [String]
htmlEngines  = ["wkhtmltopdf", "weasyprint", "pagedjs-cli", "prince", "chrome"]

engines :: [(Text, String)]
engines = map ("html",) htmlEngines ++
          map ("html5",) htmlEngines ++
          map ("latex",) latexEngines ++
          map ("beamer",) latexEngines ++
          [ ("ms", "pdfroff")
          , ("context", "context")
          ]

pdfEngines :: [String]
pdfEngines = nubOrd $ map snd engines

-- | A list of functions, each transforming the options data structure
--   in response to a command-line option.
options :: [OptDescr (Opt -> ExceptT OptInfo IO Opt)]
options =
    [ Option "fr" ["from","read"]
                 (ReqArg
                  (\arg opt -> return opt { optFrom =
                                              Just (T.toLower $ T.pack arg) })
                  "FORMAT")
                 ""

    , Option "tw" ["to","write"]
                 (ReqArg
                  (\arg opt -> return opt { optTo = Just $ T.pack arg })
                  "FORMAT")
                 ""

    , Option "o" ["output"]
                 (ReqArg
                  (\arg opt -> return opt { optOutputFile =
                                             Just (normalizePath arg) })
                  "FILE")
                 "" -- "Name of output file"

    , Option "" ["data-dir"]
                 (ReqArg
                  (\arg opt -> return opt { optDataDir =
                                  Just (normalizePath arg) })
                 "DIRECTORY") -- "Directory containing pandoc data files."
                ""

    , Option "M" ["metadata"]
                 (ReqArg
                  (\arg opt -> do
                     let (key, val) = splitField arg
                     return opt{ optMetadata = addMeta key val $
                                                 optMetadata opt })
                  "KEY[:VALUE]")
                 ""

    , Option "" ["metadata-file"]
                 (ReqArg
                  (\arg opt -> return opt{ optMetadataFiles =
                      optMetadataFiles opt ++ [normalizePath arg] })
                  "FILE")
                 ""

    , Option "d" ["defaults"]
                 (ReqArg
                  (\arg opt -> do
                     res <- liftIO $ runIO $ do
                       let defsState =
                             DefaultsState { curDefaults = Nothing,
                                             inheritanceGraph = [] }
                       fp <- fullDefaultsPath (optDataDir opt) arg
                       evalStateT (applyDefaults opt fp) defsState
                     case res of
                       Left e -> optError e
                       Right x -> return x
                  )
                  "FILE")
                ""

    , Option "" ["file-scope"]
                 (NoArg
                  (\opt -> return opt { optFileScope = True }))
                 "" -- "Parse input files before combining"

    , Option "" ["sandbox"]
                 (NoArg
                  (\opt -> return opt { optSandbox = True }))
                 ""

    , Option "s" ["standalone"]
                 (NoArg
                  (\opt -> return opt { optStandalone = True }))
                 "" -- "Include needed header and footer on output"

    , Option "" ["template"]
                 (ReqArg
                  (\arg opt ->
                     return opt{ optTemplate = Just (normalizePath arg) })
                  "FILE")
                 "" -- "Use custom template"

    , Option "V" ["variable"]
                 (ReqArg
                  (\arg opt -> do
                     let (key, val) = splitField arg
                     return opt{ optVariables =
                                  setVariable (T.pack key) (T.pack val) $
                                    optVariables opt })
                  "KEY[:VALUE]")
                 ""

    , Option "" ["wrap"]
                 (ReqArg
                  (\arg opt ->
                    case arg of
                      "auto" -> return opt{ optWrap = WrapAuto }
                      "none" -> return opt{ optWrap = WrapNone }
                      "preserve" -> return opt{ optWrap = WrapPreserve }
                      _      -> optError $ PandocOptionError
                                 "--wrap must be auto, none, or preserve")
                 "auto|none|preserve")
                 "" -- "Option for wrapping text in output"

    , Option "" ["ascii"]
                 (NoArg
                  (\opt -> return opt { optAscii = True }))
                 ""  -- "Prefer ASCII output"

    , Option "" ["toc", "table-of-contents"]
                (NoArg
                 (\opt -> return opt { optTableOfContents = True }))
               "" -- "Include table of contents"

    , Option "" ["toc-depth"]
                 (ReqArg
                  (\arg opt ->
                      case safeStrRead arg of
                           Just t | t >= 1 && t <= 6 ->
                                    return opt { optTOCDepth = t }
                           _ -> optError $ PandocOptionError
                                "TOC level must be a number 1-6")
                 "NUMBER")
                 "" -- "Number of levels to include in TOC"

    , Option "N" ["number-sections"]
                 (NoArg
                  (\opt -> return opt { optNumberSections = True }))
                 "" -- "Number sections"

    , Option "" ["number-offset"]
                 (ReqArg
                  (\arg opt ->
                      case safeStrRead ("[" <> arg <> "]") of
                           Just ns -> return opt { optNumberOffset = ns,
                                                   optNumberSections = True }
                           _      -> optError $ PandocOptionError
                                       "could not parse number-offset")
                 "NUMBERS")
                 "" -- "Starting number for sections, subsections, etc."

    , Option "" ["top-level-division"]
                 (ReqArg
                  (\arg opt ->
                      case arg of
                        "section" -> return opt{ optTopLevelDivision =
                                        TopLevelSection }
                        "chapter" -> return opt{ optTopLevelDivision =
                                        TopLevelChapter }
                        "part"    -> return opt{ optTopLevelDivision =
                                        TopLevelPart }
                        "default" -> return opt{ optTopLevelDivision =
                                        TopLevelDefault }
                        _ -> optError $ PandocOptionError $
                                "Top-level division must be " <>
                                "section,  chapter, part, or default" )
                   "section|chapter|part")
                 "" -- "Use top-level division type in LaTeX, ConTeXt, DocBook"

    , Option "" ["extract-media"]
                 (ReqArg
                  (\arg opt ->
                    return opt { optExtractMedia =
                                  Just (normalizePath arg) })
                  "PATH")
                 "" -- "Directory to which to extract embedded media"

    , Option "" ["resource-path"]
                (ReqArg
                  (\arg opt -> return opt { optResourcePath =
                                   splitSearchPath arg ++
                                    optResourcePath opt })
                   "SEARCHPATH")
                  "" -- "Paths to search for images and other resources"

    , Option "H" ["include-in-header"]
                 (ReqArg
                  (\arg opt -> return opt{ optIncludeInHeader =
                                             optIncludeInHeader opt ++
                                             [normalizePath arg] })
                  "FILE")
                 "" -- "File to include at end of header (implies -s)"

    , Option "B" ["include-before-body"]
                 (ReqArg
                  (\arg opt -> return opt{ optIncludeBeforeBody =
                                            optIncludeBeforeBody opt ++
                                            [normalizePath arg] })
                  "FILE")
                 "" -- "File to include before document body"

    , Option "A" ["include-after-body"]
                 (ReqArg
                  (\arg opt -> return opt{ optIncludeAfterBody =
                                            optIncludeAfterBody opt ++
                                            [normalizePath arg] })
                  "FILE")
                 "" -- "File to include after document body"

    , Option "" ["no-highlight"]
                (NoArg
                 (\opt -> return opt { optHighlightStyle = Nothing }))
                 "" -- "Don't highlight source code"

    , Option "" ["highlight-style"]
                (ReqArg
                 (\arg opt ->
                     return opt{ optHighlightStyle = Just $
                                 T.pack $ normalizePath arg })
                 "STYLE|FILE")
                 "" -- "Style for highlighted code"

    , Option "" ["syntax-definition"]
                (ReqArg
                 (\arg opt ->
                   return opt{ optSyntaxDefinitions = normalizePath arg :
                                optSyntaxDefinitions opt })
                 "FILE")
                "" -- "Syntax definition (xml) file"

    , Option "" ["dpi"]
                 (ReqArg
                  (\arg opt ->
                    case safeStrRead arg of
                         Just t | t > 0 -> return opt { optDpi = t }
                         _              -> optError $ PandocOptionError
                                        "dpi must be a number greater than 0")
                  "NUMBER")
                 "" -- "Dpi (default 96)"

    , Option "" ["eol"]
                 (ReqArg
                  (\arg opt ->
                    case toLower <$> arg of
                      "crlf"   -> return opt { optEol = CRLF }
                      "lf"     -> return opt { optEol = LF }
                      "native" -> return opt { optEol = Native }
                      -- mac-syntax (cr) is not supported in ghc-base.
                      _      -> optError $ PandocOptionError
                                "--eol must be crlf, lf, or native")
                  "crlf|lf|native")
                 "" -- "EOL (default OS-dependent)"

    , Option "" ["columns"]
                 (ReqArg
                  (\arg opt ->
                      case safeStrRead arg of
                           Just t | t > 0 -> return opt { optColumns = t }
                           _              -> optError $ PandocOptionError
                                   "columns must be a number greater than 0")
                 "NUMBER")
                 "" -- "Length of line in characters"

    , Option "p" ["preserve-tabs"]
                 (NoArg
                  (\opt -> return opt { optPreserveTabs = True }))
                 "" -- "Preserve tabs instead of converting to spaces"

    , Option "" ["tab-stop"]
                 (ReqArg
                  (\arg opt ->
                      case safeStrRead arg of
                           Just t | t > 0 -> return opt { optTabStop = t }
                           _              -> optError $ PandocOptionError
                                  "tab-stop must be a number greater than 0")
                  "NUMBER")
                 "" -- "Tab stop (default 4)"

    , Option "" ["pdf-engine"]
                 (ReqArg
                  (\arg opt -> do
                     let b = takeBaseName arg
                     if b `elem` pdfEngines
                        then return opt { optPdfEngine = Just arg }
                        else optError $
                              PandocOptionError $ T.pack $
                              "pdf-engine must be one of "
                               ++ intercalate ", " pdfEngines)
                  "PROGRAM")
                 "" -- "Name of program to use in generating PDF"

    , Option "" ["pdf-engine-opt"]
                 (ReqArg
                  (\arg opt -> do
                      let oldArgs = optPdfEngineOpts opt
                      return opt { optPdfEngineOpts = oldArgs ++ [arg]})
                  "STRING")
                 "" -- "Flags to pass to the PDF-engine, all instances of this option are accumulated and used"

    , Option "" ["reference-doc"]
                 (ReqArg
                  (\arg opt ->
                    return opt { optReferenceDoc = Just $ normalizePath arg })
                  "FILE")
                 "" -- "Path of custom reference doc"

    , Option "" ["self-contained"]
                 (NoArg
                  (\opt -> do
                    deprecatedOption "--self-contained" "use --embed-resources --standalone"
                    return opt { optSelfContained = True }))
                 "" -- "Make slide shows include all the needed js and css (deprecated)"

    , Option "" ["embed-resources"]
                 (NoArg
                  (\opt -> return opt { optEmbedResources = True }))
                 "" -- "Make slide shows include all the needed js and css"

    , Option "" ["request-header"]
                 (ReqArg
                  (\arg opt -> do
                     let (key, val) = splitField arg
                     return opt{ optRequestHeaders =
                       (T.pack key, T.pack val) : optRequestHeaders opt })
                  "NAME:VALUE")
                 ""

    , Option "" ["no-check-certificate"]
                (NoArg
                 (\opt -> return opt { optNoCheckCertificate = True }))
                "" -- "Disable certificate validation"

    , Option "" ["abbreviations"]
                (ReqArg
                 (\arg opt -> return opt { optAbbreviations =
                                            Just $ normalizePath arg })
                "FILE")
                "" -- "Specify file for custom abbreviations"

    , Option "" ["indented-code-classes"]
                  (ReqArg
                   (\arg opt -> return opt { optIndentedCodeClasses = T.words $
                                             T.map (\c -> if c == ',' then ' ' else c) $
                                             T.pack arg })
                   "STRING")
                  "" -- "Classes (whitespace- or comma-separated) to use for indented code-blocks"

    , Option "" ["default-image-extension"]
                 (ReqArg
                  (\arg opt -> return opt { optDefaultImageExtension = T.pack arg })
                   "extension")
                  "" -- "Default extension for extensionless images"

    , Option "F" ["filter"]
                 (ReqArg
                  (\arg opt -> return opt { optFilters =
                      optFilters opt ++ [JSONFilter (normalizePath arg)] })
                  "PROGRAM")
                 "" -- "External JSON filter"

    , Option "L" ["lua-filter"]
                 (ReqArg
                  (\arg opt -> return opt { optFilters =
                      optFilters opt ++ [LuaFilter (normalizePath arg)] })
                  "SCRIPTPATH")
                 "" -- "Lua filter"

    , Option "" ["shift-heading-level-by"]
                 (ReqArg
                  (\arg opt ->
                      case safeStrRead arg of
                           Just t ->
                               return opt{ optShiftHeadingLevelBy = t }
                           _              -> optError $ PandocOptionError
                                               "shift-heading-level-by takes an integer argument")
                  "NUMBER")
                 "" -- "Shift heading level"

    , Option "" ["base-header-level"]
                 (ReqArg
                  (\arg opt -> do
                      deprecatedOption "--base-header-level"
                        "Use --shift-heading-level-by instead."
                      case safeStrRead arg of
                           Just t | t > 0 && t < 6 ->
                               return opt{ optShiftHeadingLevelBy = t - 1 }
                           _              -> optError $ PandocOptionError
                                               "base-header-level must be 1-5")
                  "NUMBER")
                 "" -- "Headers base level"

    , Option "" ["track-changes"]
                 (ReqArg
                  (\arg opt -> do
                     action <- case arg of
                            "accept" -> return AcceptChanges
                            "reject" -> return RejectChanges
                            "all"    -> return AllChanges
                            _        -> optError $ PandocOptionError $ T.pack
                               ("Unknown option for track-changes: " ++ arg)
                     return opt { optTrackChanges = action })
                  "accept|reject|all")
                 "" -- "Accepting or reject MS Word track-changes.""

    , Option "" ["strip-comments"]
                (NoArg
                 (\opt -> return opt { optStripComments = True }))
               "" -- "Strip HTML comments"

    , Option "" ["reference-links"]
                 (NoArg
                  (\opt -> return opt { optReferenceLinks = True } ))
                 "" -- "Use reference links in parsing HTML"

    , Option "" ["reference-location"]
                 (ReqArg
                  (\arg opt -> do
                     action <- case arg of
                            "block"    -> return EndOfBlock
                            "section"  -> return EndOfSection
                            "document" -> return EndOfDocument
                            _        -> optError $ PandocOptionError $ T.pack
                               ("Unknown option for reference-location: " ++ arg)
                     return opt { optReferenceLocation = action })
                  "block|section|document")
                 "" -- "Accepting or reject MS Word track-changes.""

    , Option "" ["markdown-headings"]
                  (ReqArg
                    (\arg opt -> do
                      headingFormat <- case arg of
                        "setext" -> pure True
                        "atx" -> pure False
                        _ -> optError $ PandocOptionError $ T.pack
                          ("Unknown markdown heading format: " ++ arg ++
                            ". Expecting atx or setext")
                      pure opt { optSetextHeaders = headingFormat }
                    )
                  "setext|atx")
                  ""

    , Option "" ["list-tables"]
                 (NoArg
                  (\opt -> do
                    return opt { optListTables = True } ))
                 "" -- "Use list tables for RST"

    , Option "" ["listings"]
                 (NoArg
                  (\opt -> return opt { optListings = True }))
                 "" -- "Use listings package for LaTeX code blocks"

    , Option "i" ["incremental"]
                 (NoArg
                  (\opt -> return opt { optIncremental = True }))
                 "" -- "Make list items display incrementally in Slidy/Slideous/S5"

    , Option "" ["slide-level"]
                 (ReqArg
                  (\arg opt ->
                      case safeStrRead arg of
                           Just t | t >= 0 && t <= 6 ->
                                    return opt { optSlideLevel = Just t }
                           _      -> optError $ PandocOptionError
                                    "slide level must be a number between 0 and 6")
                 "NUMBER")
                 "" -- "Force header level for slides"

    , Option "" ["section-divs"]
                 (NoArg
                  (\opt -> return opt { optSectionDivs = True }))
                 "" -- "Put sections in div tags in HTML"

    , Option "" ["html-q-tags"]
                 (NoArg
                  (\opt ->
                     return opt { optHtmlQTags = True }))
                 "" -- "Use <q> tags for quotes in HTML"

    , Option "" ["email-obfuscation"]
                 (ReqArg
                  (\arg opt -> do
                     method <- case arg of
                            "references" -> return ReferenceObfuscation
                            "javascript" -> return JavascriptObfuscation
                            "none"       -> return NoObfuscation
                            _            -> optError $ PandocOptionError $ T.pack
                               ("Unknown obfuscation method: " ++ arg)
                     return opt { optEmailObfuscation = method })
                  "none|javascript|references")
                 "" -- "Method for obfuscating email in HTML"

     , Option "" ["id-prefix"]
                  (ReqArg
                   (\arg opt -> return opt { optIdentifierPrefix = T.pack arg })
                   "STRING")
                  "" -- "Prefix to add to automatically generated HTML identifiers"

    , Option "T" ["title-prefix"]
                 (ReqArg
                  (\arg opt ->
                    return opt {
                       optVariables =
                         setVariable "title-prefix" (T.pack arg) $
                           optVariables opt,
                       optStandalone = True })
                  "STRING")
                 "" -- "String to prefix to HTML window title"

    , Option "c" ["css"]
                 (ReqArg
                  (\arg opt -> return opt{ optCss = optCss opt ++ [arg] })
                  -- add new link to end, so it is included in proper order
                  "URL")
                 "" -- "Link to CSS style sheet"

    , Option "" ["epub-subdirectory"]
             (ReqArg
                  (\arg opt ->
                     return opt { optEpubSubdirectory = arg })
                  "DIRNAME")
                 "" -- "Name of subdirectory for epub content in OCF container"

    , Option "" ["epub-cover-image"]
                 (ReqArg
                  (\arg opt ->
                     return opt { optVariables =
                       setVariable "epub-cover-image"
                         (T.pack $ normalizePath arg) $
                         optVariables opt })
                  "FILE")
                 "" -- "Path of epub cover image"

    , Option "" ["epub-title-page"]
                 (ReqArg
                  (\arg opt ->
                    case arg of
                      "true" -> return opt{ optEpubTitlePage = True }
                      "false" -> return opt{ optEpubTitlePage = False }
                      _ -> optError $ PandocOptionError $
                                "Argument to --epub-title-page must be " <>
                                "true or false" )
                 "true|false")
                 ""

    , Option "" ["epub-metadata"]
                 (ReqArg
                  (\arg opt -> return opt { optEpubMetadata = Just $
                                             normalizePath arg })
                  "FILE")
                 "" -- "Path of epub metadata file"

    , Option "" ["epub-embed-font"]
                 (ReqArg
                  (\arg opt ->
                     return opt{ optEpubFonts = normalizePath arg :
                                                optEpubFonts opt })
                  "FILE")
                 "" -- "Directory of fonts to embed"

    , Option "" ["epub-chapter-level"]
                 (ReqArg
                  (\arg opt ->
                      case safeStrRead arg of
                           Just t | t >= 1 && t <= 6 ->
                                    return opt { optEpubChapterLevel = t }
                           _      -> optError $ PandocOptionError
                                    "chapter level must be a number between 1 and 6")
                 "NUMBER")
                 "" -- "Header level at which to split chapters in EPUB"

    , Option "" ["ipynb-output"]
                 (ReqArg
                  (\arg opt ->
                    case arg of
                      "all" -> return opt{ optIpynbOutput = IpynbOutputAll }
                      "best" -> return opt{ optIpynbOutput = IpynbOutputBest }
                      "none" -> return opt{ optIpynbOutput = IpynbOutputNone }
                      _ -> optError $ PandocOptionError
                             "ipynb-output must be all, none, or best")
                 "all|none|best")
                 "" -- "Starting number for sections, subsections, etc."

    , Option "C" ["citeproc"]
                 (NoArg
                  (\opt -> return opt { optFilters =
                      optFilters opt ++ [CiteprocFilter] }))
                 "" -- "Process citations"

    , Option "" ["bibliography"]
                 (ReqArg
                  (\arg opt -> return opt{ optMetadata =
                                            addMeta "bibliography"
                                              (normalizePath arg) $
                                              optMetadata opt })
                   "FILE")
                 ""

     , Option "" ["csl"]
                 (ReqArg
                  (\arg opt -> do
                    case lookupMeta (T.pack "csl") $ optMetadata opt of
                      Just _ -> optError $ PandocOptionError
                                   "Only one CSL file can be specified."
                      Nothing -> return opt{ optMetadata = addMeta "csl" (normalizePath arg) $
                      optMetadata opt })
                   "FILE")
                 ""

     , Option "" ["citation-abbreviations"]
                 (ReqArg
                  (\arg opt ->
                     return opt{ optMetadata =
                                  addMeta "citation-abbreviations"
                                    (normalizePath arg) $ optMetadata opt })
                   "FILE")
                 ""

    , Option "" ["natbib"]
                 (NoArg
                  (\opt -> return opt { optCiteMethod = Natbib }))
                 "" -- "Use natbib cite commands in LaTeX output"

    , Option "" ["biblatex"]
                 (NoArg
                  (\opt -> return opt { optCiteMethod = Biblatex }))
                 "" -- "Use biblatex cite commands in LaTeX output"

    , Option "" ["mathml"]
                 (NoArg
                  (\opt ->
                      return opt { optHTMLMathMethod = MathML }))
                 "" -- "Use mathml for HTML math"

    , Option "" ["webtex"]
                 (OptArg
                  (\arg opt -> do
                      let url' = fromMaybe "https://latex.codecogs.com/png.latex?" arg
                      return opt { optHTMLMathMethod = WebTeX $ T.pack url' })
                  "URL")
                 "" -- "Use web service for HTML math"

    , Option "" ["mathjax"]
                 (OptArg
                  (\arg opt -> do
                      let url' = maybe defaultMathJaxURL T.pack arg
                      return opt { optHTMLMathMethod = MathJax url'})
                  "URL")
                 "" -- "Use MathJax for HTML math"

    , Option "" ["katex"]
                 (OptArg
                  (\arg opt ->
                      return opt
                        { optHTMLMathMethod = KaTeX $
                           maybe defaultKaTeXURL T.pack arg })
                  "URL")
                  "" -- Use KaTeX for HTML Math

    , Option "" ["gladtex"]
                 (NoArg
                  (\opt ->
                      return opt { optHTMLMathMethod = GladTeX }))
                 "" -- "Use gladtex for HTML math"

    , Option "" ["trace"]
                 (NoArg
                  (\opt -> return opt { optTrace = True }))
                 "" -- "Turn on diagnostic tracing in readers."

    , Option "" ["dump-args"]
                 (NoArg
                  (\opt -> return opt { optDumpArgs = True }))
                 "" -- "Print output filename and arguments to stdout."

    , Option "" ["ignore-args"]
                 (NoArg
                  (\opt -> return opt { optIgnoreArgs = True }))
                 "" -- "Ignore command-line arguments."

    , Option "" ["verbose"]
                 (NoArg
                  (\opt -> return opt { optVerbosity = INFO }))
                 "" -- "Verbose diagnostic output."

    , Option "" ["quiet"]
                 (NoArg
                  (\opt -> return opt { optVerbosity = ERROR }))
                 "" -- "Suppress warnings."

    , Option "" ["fail-if-warnings"]
                 (NoArg
                  (\opt -> return opt { optFailIfWarnings = True }))
                 "" -- "Exit with error status if there were  warnings."

    , Option "" ["log"]
                 (ReqArg
                  (\arg opt -> return opt{ optLogFile = Just $
                                            normalizePath arg })
                "FILE")
                "" -- "Log messages in JSON format to this file."

    , Option "" ["bash-completion"]
                 (NoArg (\_ -> optInfo BashCompletion))
                 "" -- "Print bash completion script"

    , Option "" ["list-input-formats"]
                 (NoArg (\_ -> optInfo ListInputFormats))
                 ""

    , Option "" ["list-output-formats"]
                 (NoArg (\_ -> optInfo ListOutputFormats))
                 ""

    , Option "" ["list-extensions"]
                 (OptArg (\arg _ -> optInfo $ ListExtensions $ T.pack <$> arg)
                 "FORMAT")
                 ""

    , Option "" ["list-highlight-languages"]
                 (NoArg (\_ -> optInfo ListHighlightLanguages))
                 ""

    , Option "" ["list-highlight-styles"]
                 (NoArg (\_ -> optInfo ListHighlightStyles))
                 ""

    , Option "D" ["print-default-template"]
                 (ReqArg
                  (\arg opts -> optInfo $
                    PrintDefaultTemplate (optOutputFile opts) (T.pack arg))
                 "FORMAT")
                 "" -- "Print default template for FORMAT"

    , Option "" ["print-default-data-file"]
                 (ReqArg
                  (\arg opts -> optInfo $
                    PrintDefaultDataFile (optOutputFile opts) (T.pack arg))
                 "FILE")
                  "" -- "Print default data file"

    , Option "" ["print-highlight-style"]
                 (ReqArg
                  (\arg opts ->
                    optInfo $ PrintDefaultDataFile (optOutputFile opts)
                               (T.pack arg))
                  "STYLE|FILE")
                 "" -- "Print default template for FORMAT"

    , Option "v" ["version"]
                 (NoArg (\_ -> optInfo VersionInfo))
                 "" -- "Print version"

    , Option "h" ["help"]
                 (NoArg (\_ -> optInfo Help))
                 "" -- "Show help"
    ]

optError :: PandocError -> ExceptT OptInfo IO a
optError = throwError . OptError

optInfo :: OptInfo -> ExceptT OptInfo IO a
optInfo = throwError

-- Returns usage message
usageMessage :: String -> [OptDescr (Opt -> ExceptT OptInfo IO Opt)] -> String
usageMessage programName = usageInfo (programName ++ " [OPTIONS] [FILES]")

copyrightMessage :: String
copyrightMessage = intercalate "\n" [
 "Copyright (C) 2006-2022 John MacFarlane. Web:  https://pandoc.org",
 "This is free software; see the source for copying conditions. There is no",
 "warranty, not even for merchantability or fitness for a particular purpose." ]

compileInfo :: String
compileInfo =
  "\nCompiled with pandoc-types " ++ VERSION_pandoc_types ++
  ", texmath " ++ VERSION_texmath ++ ", skylighting " ++
  VERSION_skylighting ++ ",\nciteproc " ++ VERSION_citeproc ++
  ", ipynb " ++ VERSION_ipynb

handleUnrecognizedOption :: String -> [String] -> [String]
handleUnrecognizedOption "--smart" =
  (("--smart/-S has been removed.  Use +smart or -smart extension instead.\n" ++
    "For example: pandoc -f markdown+smart -t markdown-smart.") :)
handleUnrecognizedOption "--normalize" =
  ("--normalize has been removed.  Normalization is now automatic." :)
handleUnrecognizedOption "-S" = handleUnrecognizedOption "--smart"
handleUnrecognizedOption "--old-dashes" =
  ("--old-dashes has been removed.  Use +old_dashes extension instead." :)
handleUnrecognizedOption "--no-wrap" =
  ("--no-wrap has been removed.  Use --wrap=none instead." :)
handleUnrecognizedOption "--latex-engine" =
  ("--latex-engine has been removed.  Use --pdf-engine instead." :)
handleUnrecognizedOption "--latex-engine-opt" =
  ("--latex-engine-opt has been removed.  Use --pdf-engine-opt instead." :)
handleUnrecognizedOption "--chapters" =
  ("--chapters has been removed. Use --top-level-division=chapter instead." :)
handleUnrecognizedOption "--reference-docx" =
  ("--reference-docx has been removed. Use --reference-doc instead." :)
handleUnrecognizedOption "--reference-odt" =
  ("--reference-odt has been removed. Use --reference-doc instead." :)
handleUnrecognizedOption "--parse-raw" =
  ("--parse-raw/-R has been removed. Use +raw_html or +raw_tex extension.\n" :)
handleUnrecognizedOption "--epub-stylesheet" =
  ("--epub-stylesheet has been removed. Use --css instead.\n" :)
handleUnrecognizedOption "-R" = handleUnrecognizedOption "--parse-raw"
handleUnrecognizedOption x =
  (("Unknown option " ++ x ++ ".") :)

readersNames :: [Text]
readersNames = sort (map fst (readers :: [(Text, Reader PandocIO)]))

writersNames :: [Text]
writersNames = sort
  ("pdf" : map fst (writers :: [(Text, Writer PandocIO)]))

splitField :: String -> (String, String)
splitField = second (tailDef "true") . break (\c -> c == ':' || c == '=')

deprecatedOption :: String -> String -> ExceptT OptInfo IO ()
deprecatedOption o msg = do
  res <- liftIO $ runIO (report $ Deprecated (T.pack o) (T.pack msg))
  case res of
       Right () -> return ()
       Left e   -> optError e

-- | Set text value in text context.
setVariable :: Text -> Text -> Context Text -> Context Text
setVariable key val (Context ctx) = Context $ M.alter go key ctx
  where go Nothing             = Just $ toVal val
        go (Just (ListVal xs)) = Just $ ListVal $ xs ++ [toVal val]
        go (Just x)            = Just $ ListVal [x, toVal val]

addMeta :: String -> String -> Meta -> Meta
addMeta k v meta =
  case lookupMeta k' meta of
       Nothing -> setMeta k' v' meta
       Just (MetaList xs) ->
                  setMeta k' (MetaList (xs ++ [v'])) meta
       Just x  -> setMeta k' (MetaList [x, v']) meta
 where
  v' = readMetaValue v
  k' = T.pack k

readMetaValue :: String -> MetaValue
readMetaValue s
  | s == "true"  = MetaBool True
  | s == "True"  = MetaBool True
  | s == "TRUE"  = MetaBool True
  | s == "false" = MetaBool False
  | s == "False" = MetaBool False
  | s == "FALSE" = MetaBool False
  | otherwise    = MetaString $ T.pack s

-- On Windows with ghc 8.6+, we need to rewrite paths
-- beginning with \\ to \\?\UNC\. -- See #5127.
normalizePath :: FilePath -> FilePath
#ifdef _WINDOWS
normalizePath fp =
  if "\\\\" `isPrefixOf` fp && not ("\\\\?\\" `isPrefixOf` fp)
    then "\\\\?\\UNC\\" ++ drop 2 fp
    else fp
#else
normalizePath = id
#endif
