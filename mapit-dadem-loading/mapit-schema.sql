--
-- mapit-schema.sql:
-- Schema for the MaPit SQLite database.
--
-- Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: mapit-schema.sql,v 1.1 2004-11-25 13:39:26 chris Exp $
--

-- description of areas
create table area (
    id integer not null primary key,
    parent_area_id integer,
    unit_id integer,        -- ESRI shapefile unit ID
    ons_code text,          -- six-digit ward code
    type char(3),           -- 'CTY' or whatever
    -- Country in which this area lies.
    -- 'E'  England
    -- 'N'  Northern Ireland
    -- 'S'  Scotland
    -- 'W'  Wales
    country char(1)
);

-- different names of areas
create table area_name (
    area_id integer not null,
    -- Which type of name this is.
    -- 'O'  name used by Ordnance Survey
    -- 'S'           ... ONS
    -- 'G'           ... GovEval
    -- 'F'  "friendly" name for our own use
    name_type char(1),
    name text,
    primary key (area_id, name_type)
);

create index area_name_area_id_idx on area_name(area_id);

-- lookup table for postcodes
create table postcode (
    postcode varchar(8) not null primary key,
    id integer not null,
    easting number,
    northing number
);

create unique index postcode_id_idx on postcode(id);

-- mapping from postcodes to areas
create table postcode_area (
    postcode_id integer not null,
    area_id integer not null
);

create index postcode_area_postcode_id_idx on postcode_area(postcode_id);
