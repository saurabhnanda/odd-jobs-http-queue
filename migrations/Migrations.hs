module Migrations where

import Database.PostgreSQL.Simple as PGS
import Database.PostgreSQL.Simple.Types as PGS
import OddJobs.Migrations as Job
import Types (jobTable, sinkChangedChannel)
import Data.Functor (void)
import Debug.Trace
import UnliftIO (bracket)
import Common (dbCredParser)
import Options.Applicative as Opts

createHttpSourceTableQuery :: Query
createHttpSourceTableQuery =
  "create table if not exists ? " <>
  "( id serial primary key" <>
  ", method text not null" <>
  ", path text not null" <>
  ", query text" <>
  ", headers text[][]" <>
  ", body bytea" <>
  ", created_at timestamp with time zone default now () not null" <>
  ", remaining int not null" <>
  ")"

createHttpSinkTableQuery :: Query
createHttpSinkTableQuery =
  "create table if not exists ?" <>
  "( id serial primary key" <>
  ", active boolean not null default true" <>
  ", source_path text not null" <>
  ", sink_url text not null" <>
  ", created_at timestamp with time zone default now() not null" <>
  "); \n" <>
  "create unique index if not exists ? on ?(source_path, sink_url);"

createSinkTrigger :: Query
createSinkTrigger =
  "create or replace function notify_sink_changed() returns trigger as $$" <>
  "begin \n" <>
  "  notify ?;\n" <>
  "  return null;" <>
  "end; \n" <>
  "$$ language plpgsql;\n" <>
  "drop trigger if exists trg_notify_sink_changed on http_sinks;\n" <>
  "create trigger trg_notify_sink_changed after insert or update on http_sinks for each statement execute procedure notify_sink_changed();"

runMigrations :: Connection -> IO ()
runMigrations conn = do
  Job.createJobTable conn jobTable
  void $ PGS.execute conn createHttpSourceTableQuery (Only $ PGS.Identifier "http_requests")
  void $ PGS.execute conn createHttpSinkTableQuery ( PGS.Identifier "http_sinks"
                                                   , PGS.Identifier "idx_uniq_http_sink"
                                                   , PGS.Identifier "http_sinks"
                                                   )
  void $ PGS.execute conn createSinkTrigger (Only sinkChangedChannel)

main :: IO ()
main = do
  let parserPrefs = prefs $ showHelpOnEmpty <> showHelpOnError
      parserInfo =  info (dbCredParser  <**> helper) fullDesc
  connInfo <- customExecParser parserPrefs parserInfo
  bracket (PGS.connect connInfo) PGS.close runMigrations
