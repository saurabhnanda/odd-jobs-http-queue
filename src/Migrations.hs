module Migrations where

import Database.PostgreSQL.Simple as PGS
import Database.PostgreSQL.Simple.Types as PGS
import OddJobs.Migrations as Job
import Types (jobTable, sinkChangedChannel)
import Data.Functor (void)
import Debug.Trace
import UnliftIO (bracket)

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
  ")"

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
  traceM "MIGRATIONS 1"
  Job.createJobTable conn jobTable
  traceM "MIGRATIONS 2"
  void $ PGS.execute conn createHttpSourceTableQuery (Only $ PGS.Identifier "http_requests")
  traceM "MIGRATIONS 3"
  void $ PGS.execute conn createHttpSinkTableQuery (Only $ PGS.Identifier "http_sinks")
  traceM "MIGRATIONS 4"
  void $ PGS.execute conn createSinkTrigger (Only sinkChangedChannel)
  traceM "MIGRATIONS 5"

main :: IO ()
main = bracket (PGS.connectPostgreSQL "dbname=http_queue user=b2b password=b2b host=localhost") PGS.close runMigrations
