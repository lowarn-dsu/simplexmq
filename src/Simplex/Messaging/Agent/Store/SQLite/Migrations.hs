{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations
  ( Migration (..),
    MigrationsToRun (..),
    MTRError (..),
    DownMigration (..),
    app,
    initialize,
    get,
    run,
    getCurrent,
    mtrErrorDescription,
    -- for unit tests
    migrationsToRun,
    toDownMigration,
  )
where

import Control.Monad (forM_, when)
import Data.Aeson (ToJSON)
import qualified Data.Aeson as J
import Data.List (intercalate, sortOn)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map as M
import Data.Maybe (isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Clock (getCurrentTime)
import Database.SQLite.Simple (Connection, Only (..), Query (..))
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.QQ (sql)
import qualified Database.SQLite3 as SQLite3
import GHC.Generics (Generic)
import Simplex.Messaging.Agent.Protocol (extraSMPServerHosts)
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220101_initial
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220301_snd_queue_keys
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220322_notifications
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220608_v2
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220625_v2_ntf_mode
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220811_onion_hosts
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220817_connection_ntfs
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220905_commands
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220915_connection_queues
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230110_users
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230117_fkey_indexes
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230120_delete_errors
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230217_server_key_hash
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230223_files
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230320_retry_state
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230401_snd_files
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (dropPrefix, sumTypeJSON)
import Simplex.Messaging.Transport.Client (TransportHost)

data Migration = Migration {name :: String, up :: Text, down :: Maybe Text}
  deriving (Eq, Show)

schemaMigrations :: [(String, Query, Maybe Query)]
schemaMigrations =
  [ ("20220101_initial", m20220101_initial, Nothing),
    ("20220301_snd_queue_keys", m20220301_snd_queue_keys, Nothing),
    ("20220322_notifications", m20220322_notifications, Nothing),
    ("20220607_v2", m20220608_v2, Nothing),
    ("m20220625_v2_ntf_mode", m20220625_v2_ntf_mode, Nothing),
    ("m20220811_onion_hosts", m20220811_onion_hosts, Nothing),
    ("m20220817_connection_ntfs", m20220817_connection_ntfs, Nothing),
    ("m20220905_commands", m20220905_commands, Nothing),
    ("m20220915_connection_queues", m20220915_connection_queues, Nothing),
    ("m20230110_users", m20230110_users, Nothing),
    ("m20230117_fkey_indexes", m20230117_fkey_indexes, Nothing),
    ("m20230120_delete_errors", m20230120_delete_errors, Nothing),
    ("m20230217_server_key_hash", m20230217_server_key_hash, Nothing),
    ("m20230223_files", m20230223_files, Just down_m20230223_files),
    ("m20230320_retry_state", m20230320_retry_state, Just down_m20230320_retry_state),
    ("m20230401_snd_files", m20230401_snd_files, Just down_m20230401_snd_files)
  ]

-- | The list of migrations in ascending order by date
app :: [Migration]
app = sortOn name $ map migration schemaMigrations
  where
    migration (name, up, down) = Migration {name, up = fromQuery up, down = fromQuery <$> down}

get :: Connection -> [Migration] -> IO (Either MTRError MigrationsToRun)
get db migrations = migrationsToRun migrations <$> getCurrent db

getCurrent :: Connection -> IO [Migration]
getCurrent db = map toMigration <$> DB.query_ db "SELECT name, down FROM migrations ORDER BY name ASC;"
  where
    toMigration (name, down) = Migration {name, up = "", down}

run :: Connection -> MigrationsToRun -> IO ()
run db = \case
  MTRUp ms -> mapM_ runUp ms
  MTRDown ms -> mapM_ runDown $ reverse ms
  MTRNone -> pure ()
  where
    runUp Migration {name, up, down} = do
      when (name == "m20220811_onion_hosts") updateServers
      DB.withImmediateTransaction db $ insert >> execSQL up
      where
        insert = DB.execute db "INSERT INTO migrations (name, down, ts) VALUES (?,?,?)" . (name,down,) =<< getCurrentTime
        updateServers = forM_ (M.assocs extraSMPServerHosts) $ \(h, h') ->
          DB.withImmediateTransaction db $
            let hs = decodeLatin1 . strEncode $ ([h, h'] :: NonEmpty TransportHost)
             in DB.execute db "UPDATE servers SET host = ? WHERE host = ?" (hs, decodeLatin1 $ strEncode h)
    runDown DownMigration {downName, downQuery} = do
      DB.withImmediateTransaction db $ do
        execSQL downQuery
        DB.execute db "DELETE FROM migrations WHERE name = ?" (Only downName)
    execSQL = SQLite3.exec $ DB.connectionHandle db

initialize :: Connection -> IO ()
initialize db = do
  cs :: [Text] <- map fromOnly <$> DB.query_ db "SELECT name FROM pragma_table_info('migrations')"
  case cs of
    [] -> createMigrations
    _ -> when ("down" `notElem` cs) $ DB.execute_ db "ALTER TABLE migrations ADD COLUMN down TEXT"
  where
    createMigrations =
      DB.execute_
        db
        [sql|
          CREATE TABLE IF NOT EXISTS migrations (
            name TEXT NOT NULL,
            ts TEXT NOT NULL,
            down TEXT,
            PRIMARY KEY (name)
          );
        |]

data DownMigration = DownMigration {downName :: String, downQuery :: Text}
  deriving (Eq, Show)

toDownMigration :: Migration -> Maybe DownMigration
toDownMigration Migration {name, down} = DownMigration name <$> down

data MigrationsToRun = MTRUp [Migration] | MTRDown [DownMigration] | MTRNone
  deriving (Eq, Show)

data MTRError
  = MTRENoDown {dbMigrations :: [String]}
  | MTREDifferent {appMigration :: String, dbMigration :: String}
  deriving (Eq, Show, Generic)

instance ToJSON MTRError where
  toJSON = J.genericToJSON . sumTypeJSON $ dropPrefix "MTRE"
  toEncoding = J.genericToEncoding . sumTypeJSON $ dropPrefix "MTRE"

mtrErrorDescription :: MTRError -> String
mtrErrorDescription = \case
  MTRENoDown ms -> "database version is newer than the app, but no down migration for: " <> intercalate ", " ms
  MTREDifferent a d -> "different migration in the app/database: " <> a <> " / " <> d

migrationsToRun :: [Migration] -> [Migration] -> Either MTRError MigrationsToRun
migrationsToRun [] [] = Right MTRNone
migrationsToRun appMs [] = Right $ MTRUp appMs
migrationsToRun [] dbMs
  | length dms == length dbMs = Right $ MTRDown dms
  | otherwise = Left $ MTRENoDown $ mapMaybe nameNoDown dbMs
  where
    dms = mapMaybe toDownMigration dbMs
    nameNoDown m = if isNothing (down m) then Just $ name m else Nothing
migrationsToRun (a : as) (d : ds)
  | name a == name d = migrationsToRun as ds
  | otherwise = Left $ MTREDifferent (name a) (name d)
