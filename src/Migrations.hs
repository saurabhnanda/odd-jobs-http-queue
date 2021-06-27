module Migrations where

import Database.PostgreSQL.Simple as PGS
import Database.PostgreSQL.Simple.Types as PGS
import OddJobs.Migrations as Job
import Types (jobTable)
import Data.Functor (void)

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
  ")"

createHttpSinkTableQuery :: Query
createHttpSinkTableQuery =
  "create table if not exists ?" <>
  "( id serial primary key" <>
  ", active boolean not null default true" <>
  ", source_path text not null" <>
  ", sink_host text not null" <>
  ", sink_path text not null" <>
  ", created_at timestamp with time zone default now() not null" <>
  ")"

runMigrations :: Connection -> IO ()
runMigrations conn = do
  Job.createJobTable conn jobTable
  void $ PGS.execute conn createHttpSourceTableQuery (Only $ PGS.Identifier "http_requests")
  void $ PGS.execute conn createHttpSinkTableQuery (Only $ PGS.Identifier "http_sinks")

