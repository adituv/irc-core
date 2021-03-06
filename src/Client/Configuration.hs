{-# Language OverloadedStrings #-}
{-# Language TemplateHaskell #-}
{-# Language BangPatterns #-}
{-# Language RecordWildCards #-}

{-|
Module      : Client.Configuration
Description : Client configuration format and operations
Copyright   : (c) Eric Mertens, 2016
License     : ISC
Maintainer  : emertens@gmail.com

This module defines the top-level configuration information for the client.
-}

module Client.Configuration
  (
  -- * Configuration type
    Configuration(..)
  , ConfigurationFailure(..)
  , configDefaults
  , configServers
  , configPalette

  -- * Loading configuration
  , loadConfiguration

  -- * Resolving paths
  , resolveConfigurationPath
  ) where

import           Client.Image.Palette
import           Client.Configuration.Colors
import           Client.ServerSettings
import           Control.Applicative
import           Control.Exception
import           Control.Monad
import           Config
import           Config.FromConfig
import           Control.Lens hiding (List)
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import           Data.Maybe
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import           Data.Traversable
import           Graphics.Vty.Attributes
import           Irc.Identifier (Identifier, mkId)
import           Network.Socket (HostName)
import           System.Directory
import           System.FilePath
import           System.IO.Error

-- | Top-level client configuration information. When connecting to a
-- server configuration from '_configServers' is used where possible,
-- otherwise '_configDefaults' is used.
data Configuration = Configuration
  { _configDefaults :: ServerSettings -- ^ Default connection settings
  , _configServers  :: (HashMap HostName ServerSettings) -- ^ Host-specific settings
  , _configPalette  :: Palette
  }
  deriving Show

makeLenses ''Configuration

data ConfigurationFailure
  = ConfigurationParseFailed String
  | ConfigurationMalformed String
  | ConfigurationReadFailed String
  deriving Show

instance Exception ConfigurationFailure

-- | Uses 'getAppUserDataDirectory' to find @.glirc/config@
getOldConfigPath :: IO FilePath
getOldConfigPath =
  do dir <- getAppUserDataDirectory "glirc"
     return (dir </> "config")

-- | Uses 'getXdgDirectory' 'XdgConfig' to find @.config/glirc/config@
getNewConfigPath :: IO FilePath
getNewConfigPath =
  do dir <- getXdgDirectory XdgConfig "glirc"
     return (dir </> "config")

-- | Empty configuration file used when no path is specified
-- and the configuration file is missing.
emptyConfigFile :: Text
emptyConfigFile = "{}\n"

-- | Attempt to read a file using the given handler when
-- a file does not exist. On failure a 'ConfigurationReadFailed'
-- exception is throw.
readFileCatchNotFound ::
  FilePath {- ^ file to read -} ->
  (IOError -> IO Text) {- ^ error handler for not found case -} ->
  IO Text
readFileCatchNotFound path onNotFound =
  do res <- try (Text.readFile path)
     case res of
       Left e | isDoesNotExistError e -> onNotFound e
              | otherwise -> throwIO (ConfigurationReadFailed (show e))
       Right txt -> return txt

-- | Either read a configuration file from one of the default
-- locations, in which case no configuration found is equivalent
-- to an empty configuration, or from the specified file where
-- no configuration found is an error.
readConfigurationFile ::
  Maybe FilePath {- ^ just file or use default search paths -} ->
  IO Text
readConfigurationFile mbPath =
  case mbPath of

    Just path ->
      readFileCatchNotFound path $ \e ->
        throwIO (ConfigurationReadFailed (show e))

    Nothing ->
      do newPath <- getNewConfigPath
         readFileCatchNotFound newPath $ \_ ->
           do oldPath <- getOldConfigPath
              readFileCatchNotFound oldPath $ \_ ->
                return emptyConfigFile


-- | Load the configuration file defaulting to @~/.glirc/config@.
loadConfiguration ::
  Maybe FilePath {- ^ path to configuration file -} ->
  IO (Either ConfigurationFailure Configuration)
loadConfiguration mbPath = try $
  do file <- readConfigurationFile mbPath
     def  <- loadDefaultServerSettings

     rawcfg <-
       case parse file of
         Left parseError -> throwIO (ConfigurationParseFailed parseError)
         Right rawcfg -> return rawcfg

     case runConfigParser (parseConfiguration def rawcfg) of
       Left loadError -> throwIO (ConfigurationMalformed (Text.unpack loadError))
       Right cfg -> return cfg


parseConfiguration :: ServerSettings -> Value -> ConfigParser Configuration
parseConfiguration def = parseSections $

  do _configDefaults <- fromMaybe def
                    <$> sectionOptWith (parseServerSettings def) "defaults"

     _configServers  <- fromMaybe HashMap.empty
                    <$> sectionOptWith (parseServers _configDefaults) "servers"

     _configPalette <- fromMaybe defaultPalette
                    <$> sectionOptWith parsePalette "palette"

     return Configuration{..}

parsePalette :: Value -> ConfigParser Palette
parsePalette (Sections ss) = foldM paletteHelper defaultPalette ss
parsePalette _             = failure "Expected sections"

paletteHelper :: Palette -> Section -> ConfigParser Palette
paletteHelper p (Section k v) =
  extendLoc k $
  case k of
    "nick-colors" -> do xs <- parseColors v
                        return $! set palNicks xs p

    "time"        -> setAttr palTime
    "meta"        -> setAttr palMeta
    "sigil"       -> setAttr palSigil
    "label"       -> setAttr palLabel
    "latency"     -> setAttr palLatency
    "error"       -> setAttr palError
    "textbox"     -> setAttr palTextBox
    "window-name" -> setAttr palWindowName
    "activity"    -> setAttr palActivity
    "mention"     -> setAttr palMention
    _             -> failure "Unknown palette entry"
  where
    setAttr l =
      do x <- parseColor v
         let !attr = withForeColor defAttr x
         return $! set l attr p


parseServers :: ServerSettings -> Value -> ConfigParser (HashMap HostName ServerSettings)
parseServers def (List xs) =
  do ys <- traverse (parseServerSettings def) xs
     return (HashMap.fromList [(view ssHostName ss, ss) | ss <- ys])
parseServers _ _ = failure "expected list"

sectionOptString :: Text -> SectionParser (Maybe String)
sectionOptString key = fmap Text.unpack <$> sectionOpt key

sectionOptStrings :: Text -> SectionParser (Maybe [String])
sectionOptStrings key = fmap (fmap Text.unpack) <$> sectionOpt key

sectionOptNum :: Num a => Text -> SectionParser (Maybe a)
sectionOptNum key = fmap fromInteger <$> sectionOpt key

sectionOptIdentifiers :: Text -> SectionParser (Maybe [Identifier])
sectionOptIdentifiers key = fmap (fmap mkId) <$> sectionOpt key

parseServerSettings :: ServerSettings -> Value -> ConfigParser ServerSettings
parseServerSettings !def =
  parseSections $
    do _ssNick           <- fieldReq  ssNick          "nick"
       _ssUser           <- fieldReq  ssUser          "username"
       _ssReal           <- fieldReq  ssReal          "realname"
       _ssUserInfo       <- fieldReq  ssUserInfo      "userinfo"
       _ssPassword       <- field     ssPassword      "password"
       _ssSaslUsername   <- field     ssSaslUsername  "sasl-username"
       _ssSaslPassword   <- field     ssSaslPassword  "sasl-password"
       _ssHostName       <- fieldReq' ssHostName      (sectionOptString "hostname")
       _ssPort           <- field'    ssPort          (sectionOptNum "port")
       _ssTls            <- fieldReq' ssTls           (boolean "tls")
       _ssTlsInsecure    <- fieldReq' ssTlsInsecure   (boolean "tls-insecure")
       _ssTlsClientCert  <- field'    ssTlsClientCert (sectionOptString "tls-client-cert")
       _ssTlsClientKey   <- field'    ssTlsClientKey  (sectionOptString "tls-client-key")
       _ssConnectCmds    <- fieldReq  ssConnectCmds   "connect-cmds"
       _ssSocksHost      <- field'    ssSocksHost     (sectionOptString "socks-host")
       _ssSocksPort      <- fieldReq' ssSocksPort     (sectionOptNum "socks-port")
       _ssServerCerts    <- fieldReq' ssServerCerts   (sectionOptStrings "server-certificates")
       _ssChanservChannels <- fieldReq' ssChanservChannels (sectionOptIdentifiers "chanserv-channels")
       _ssFloodPenalty   <- fieldReq ssFloodPenalty   "flood-penalty"
       _ssFloodThreshold <- fieldReq ssFloodThreshold "flood-threshold"
       _ssMessageHooks   <- fieldReq ssMessageHooks   "message-hooks"
       return ServerSettings{..}
  where
    field    l key = field'    l (sectionOpt key)
    fieldReq l key = fieldReq' l (sectionOpt key)

    fieldReq' l p = fromMaybe (view l def) <$> p

    field' l p = (<|> view l def) <$> p

boolean :: Text -> SectionParser (Maybe Bool)
boolean key =
  do mb <- sectionOpt key
     for mb $ \a ->
       case atomName a of
         "yes" -> return True
         "no"  -> return False
         _     -> liftConfigParser (failure "expected yes or no")

-- | Resolve relative paths starting at the home directory rather than
-- the current directory of the client.
resolveConfigurationPath :: FilePath -> IO FilePath
resolveConfigurationPath path
  | isAbsolute path = return path
  | otherwise = do home <- getHomeDirectory
                   return (home </> path)
