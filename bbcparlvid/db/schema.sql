-- 
-- schema.sql:
-- Schema for bbcparlvid database.
--
-- Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
-- Email: etienne@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: schema.sql,v 1.1 2007-08-22 16:39:32 etienne Exp $
--

DROP TABLE raw_footage;
DROP TABLE programmes CASCADE;
DROP TABLE filenames;
DROP SEQUENCE programmes_seq;

-- raw-footage is used to keep track of the status of downloaded video
-- from the BBC Parliament online stream (windows media player)

CREATE TABLE raw_footage (
  filename varchar(255) PRIMARY KEY NOT NULL,
  start_dt timestamp NOT NULL,
  end_dt timestamp NOT NULL,
  status varchar(100) NOT NULL default 'not-yet-processed'
);

ALTER TABLE raw_footage CLUSTER ON raw_footage_pkey;

create index rawfootage_start_idx on raw_footage(start_dt);
create index rawfootage_end_idx on raw_footage(end_dt);

-- programmes is used to keep track of programmes that we have
-- downloaded in raw footage - for programmes where we have
-- re-distribution rights, we will have converted them into flash
-- video / mp4 / whatever.

CREATE SEQUENCE programmes_seq;

CREATE TABLE programmes (
  id integer NOT NULL PRIMARY KEY DEFAULT nextval('programmes_seq'),
  location varchar(100) NOT NULL,
  broadcast_start timestamp NOT NULL,
  broadcast_end timestamp NOT NULL,
  record_start timestamp,
  record_end timestamp,
  title varchar(255),
  synopsis varchar(1000),
  crid varchar(255),
  channel_id varchar(255),
  status varchar(255) NOT NULL default 'not-yet-processed',
  rights varchar(255) NOT NULL default 'none');

ALTER TABLE programmes CLUSTER ON programmes_pkey;

create index programmes_broadcast_start_idx on programmes(broadcast_start);
create index programmes_broadcast_end_idx on programmes(broadcast_end);
create index programmes_channel_id_idx on programmes(channel_id);

CREATE TABLE filenames (
  id INTEGER NOT NULL REFERENCES programmes (id),
  filename varchar(255) NOT NULL,
  filetype varchar(100));

create index filenames_id_idx on filenames (id);
create index filenames_filename_idx on filenames (filename);