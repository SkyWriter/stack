{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Template name handling.

module Stack.Types.TemplateName where

import           Data.Aeson.Extended (FromJSON, withText, parseJSON)
import           Data.Aeson.Types (typeMismatch)
import qualified Data.Text as T
import           Data.Yaml (Value(Object), (.:?))
import           Language.Haskell.TH
import           Network.HTTP.Client (parseRequest)
import qualified Options.Applicative as O
import           Path
import           Path.Internal
import           Stack.Prelude

-- | A template name.
data TemplateName = TemplateName !Text !TemplatePath
  deriving (Ord,Eq,Show)

data TemplatePath = AbsPath (Path Abs File)
                  -- ^ an absolute path on the filesystem
                  | RelPath (Path Rel File)
                  -- ^ a relative path on the filesystem, or relative to
                  -- the template repository
                  | UrlPath String
                  -- ^ a full URL
                  | RepoPath RepoTemplatePath
  deriving (Eq, Ord, Show)

-- | Details for how to access a template from a remote repo.
data RepoTemplatePath = RepoTemplatePath
    { rtpService  :: RepoService
    , rtpUser     :: Text
    , rtpTemplate :: Text
    }
    deriving (Eq, Ord, Show)

-- | Services from which templates can be retrieved from a repository.
data RepoService = Github | Gitlab | Bitbucket
    deriving (Eq, Ord, Show)

instance FromJSON TemplateName where
    parseJSON = withText "TemplateName" $
        either fail return . parseTemplateNameFromString . T.unpack

data TemplateInfo = TemplateInfo
  { author      :: Maybe Text
  , description :: Maybe Text }
  deriving (Eq, Ord, Show)

instance FromJSON TemplateInfo where
  parseJSON (Object v) = TemplateInfo <$> v .:? "author" <*> v .:? "description"
  parseJSON invalid = typeMismatch "Template Info" invalid

-- | An argument which accepts a template name of the format
-- @foo.hsfiles@ or @foo@, ultimately normalized to @foo@.
templateNameArgument :: O.Mod O.ArgumentFields TemplateName
                     -> O.Parser TemplateName
templateNameArgument =
    O.argument
        (do string <- O.str
            either O.readerError return (parseTemplateNameFromString string))

-- | An argument which accepts a @key:value@ pair for specifying parameters.
templateParamArgument :: O.Mod O.OptionFields (Text,Text)
                      -> O.Parser (Text,Text)
templateParamArgument =
    O.option
        (do string <- O.str
            either O.readerError return (parsePair string))
  where
    parsePair :: String -> Either String (Text, Text)
    parsePair s =
        case break (==':') s of
            (key,':':value@(_:_)) -> Right (T.pack key, T.pack value)
            _ -> Left ("Expected key:value format for argument: " <> s)

-- | Parse a template name from a string.
parseTemplateNameFromString :: String -> Either String TemplateName
parseTemplateNameFromString fname =
    case T.stripSuffix ".hsfiles" (T.pack fname) of
        Nothing -> parseValidFile (T.pack fname) (fname <> ".hsfiles") fname
        Just prefix -> parseValidFile prefix fname fname
  where
    parseValidFile prefix hsf orig = maybe (Left expected) Right
                                           $ asum (validParses prefix hsf orig)
    validParses prefix hsf orig =
        -- NOTE: order is important
        [ TemplateName prefix        . RepoPath <$> parseRepoPath hsf
        , TemplateName (T.pack orig) . UrlPath <$> (parseRequest orig *> Just orig)
        , TemplateName prefix        . AbsPath <$> parseAbsFile hsf
        , TemplateName prefix        . RelPath <$> parseRelFile hsf
        ]
    expected = "Expected a template like: foo or foo.hsfiles or\
               \ https://example.com/foo.hsfiles or github:user/foo"

-- | Make a template name.
mkTemplateName :: String -> Q Exp
mkTemplateName s =
    case parseTemplateNameFromString s of
        Left{} -> runIO $ throwString ("Invalid template name: " ++ show s)
        Right (TemplateName (T.unpack -> prefix) p) ->
            [|TemplateName (T.pack prefix) $(pn)|]
            where pn =
                      case p of
                          AbsPath (Path fp) -> [|AbsPath (Path fp)|]
                          RelPath (Path fp) -> [|RelPath (Path fp)|]
                          UrlPath fp -> [|UrlPath fp|]
                          RepoPath (RepoTemplatePath sv u t) ->
                            case sv of
                                Github    -> [|RepoPath $ RepoTemplatePath Github u t|]
                                Gitlab    -> [|RepoPath $ RepoTemplatePath Gitlab u t|]
                                Bitbucket -> [|RepoPath $ RepoTemplatePath Bitbucket u t|]

-- | Get a text representation of the template name.
templateName :: TemplateName -> Text
templateName (TemplateName prefix _) = prefix

-- | Get the path of the template.
templatePath :: TemplateName -> TemplatePath
templatePath (TemplateName _ fp) = fp

defaultRepoUserForService :: RepoService -> Maybe Text
defaultRepoUserForService Github = Just "commercialhaskell"
defaultRepoUserForService _      = Nothing

-- | Parses a template path of the form @github:user/template@.
parseRepoPath :: String -> Maybe RepoTemplatePath
parseRepoPath s =
  case T.splitOn ":" (T.pack s) of
    ["github"    , rest] -> parseRepoPathWithService Github rest
    ["gitlab"    , rest] -> parseRepoPathWithService Gitlab rest
    ["bitbucket" , rest] -> parseRepoPathWithService Bitbucket rest
    _                    -> Nothing

-- | Parses a template path of the form @user/template@, given a service
parseRepoPathWithService :: RepoService -> Text -> Maybe RepoTemplatePath
parseRepoPathWithService service path =
  case T.splitOn "/" path of
    [user, name] -> Just $ RepoTemplatePath service user name
    [name]       -> do
        repoUser <- defaultRepoUserForService service
        Just $ RepoTemplatePath service repoUser name
    _            -> Nothing

